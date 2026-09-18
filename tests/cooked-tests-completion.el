;;; cooked-tests-completion.el --- Completing at a prompt, in Emacs and in zsh -*- lexical-binding: t; -*-

;;; Commentary:

;; Both tables: the native one that ships loaded, and the round trip that asks the
;; child's own completion system over OSC 51;C.  The shell half is mostly driven by
;; a stub that answers on demand, so the protocol can be tested without zsh's
;; timing.
;;
;; `cooked-shell-completion' is required here, so most of this file runs with the
;; layer loaded -- which is how the layer gets tested at all.  The tests for the
;; *unloaded* state bind the three seams back to nil rather than arranging a second
;; Emacs, for the same reason `cooked-osc-51-is-closed-until-opted-in' binds
;; `cooked-osc-eval-functions': the variables are not a proxy for the layer being
;; absent, they are the entire mechanism by which the core notices it.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-shell-completion)

(ert-deftest cooked-completion-offers-programs-then-files ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (and (string-match-p "ready" (cooked-tests--text))
                             (cooked--input-start-position)))))
    ;; First word: programs on PATH.
    (goto-char cooked--input-end)
    (insert "ls")
    (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
      (should (= start (cooked--input-start-position)))
      (should (= end (point)))
      (should (member "ls" (all-completions "ls" table))))
    ;; Later words complete as file names, relative to the child's directory.
    (insert " REA")
    (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
      (should (> start (cooked--input-start-position)))
      (should (= end (point)))
      (let ((default-directory (file-name-directory
                                (directory-file-name cooked--source-directory))))
        (should (member "README.org" (all-completions "REA" table)))))))

(defun cooked-tests--indexed (records)
  "Index RECORDS as (MATCHES ANNOTATE GROUP), for reading the answers back.

`cooked--completion-index' fills two tables the *caller* owns, because the live
path has to refill them as the shell is asked again while the word grows -- see
`cooked--completion-dynamic', which is handed the same two tables the CAPF's
`:annotation-function' closes over.  A test only ever wants to look an answer
up, so this wraps them in the two lookup functions that path ends up exposing.

A fixture rather than something the layer provides: it owns its tables, which is
exactly what makes it useless to the code under test."
  (let ((annotations (make-hash-table :test #'equal))
        (groups (make-hash-table :test #'equal)))
    (list (cooked--completion-index records "" annotations groups)
          (lambda (candidate) (gethash candidate annotations))
          (lambda (candidate transform)
            (if transform candidate (gethash candidate groups))))))

(ert-deftest cooked-completion-reply-becomes-candidates ()
  "The shell's answer, decoded: candidates, their descriptions, their groups."
  (with-temp-buffer
    (cooked--completion-handle
     (cooked-tests--completion-reply
      3 4 '(("checkout" "checkout   -- switch branches" "%B%F{cyan}>> command%f%b")
            ("check-attr" "check-attr -- gitattributes" "-default-"))))
    (pcase-let ((`(,serial ,prefix ,_suffix ,truncated . ,records)
                 cooked--completion-reply))
      (should-not truncated)
      (should (= serial 3))
      (should (= prefix 4))
      (pcase-let ((`(,matches ,annotate ,group)
                   (cooked-tests--indexed records)))
        (should (equal matches '("checkout" "check-attr")))
        (should (equal (funcall annotate "checkout") " switch branches"))
        ;; The heading is what compsys would have printed, prompt escapes and all.
        (should (equal (funcall group "checkout" nil) "command"))
        ;; zsh's name for "no group": a heading of "-default-" is worse than none.
        (should-not (funcall group "check-attr" nil))))))

(ert-deftest cooked-completion-keeps-the-annotated-half-of-a-duplicate ()
  "zsh offers a branch under both `heads' and `commits'; only one is worth showing."
  (with-temp-buffer
    (cooked--completion-handle
     (cooked-tests--completion-reply
      1 2 '(("main" "main" "-default-")
            ("main" "main -- [76165fd] the tip" "branch"))))
    (pcase-let* ((`(,_serial ,_prefix ,_suffix ,_truncated . ,records)
                  cooked--completion-reply)
                 (`(,matches ,annotate ,_group) (cooked-tests--indexed records)))
      (should (equal matches '("main")))
      (should (equal (funcall annotate "main") " [76165fd] the tip")))))

(ert-deftest cooked-completion-filters-a-complete-answer-in-emacs ()
  "A list the shell sent whole needs no second query as the word grows."
  (cooked-tests--with-stub-shell
      '(("git chec" . (4 0 nil ("checkout" "" "") ("check-attr" "" ""))))
      queries
    (let* ((table (cooked--completion-dynamic
                   "git " "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                   '("chec" nil ("checkout" "" "") ("check-attr" "" ""))))
           (grown (all-completions "checko" table)))
      (should (equal grown '("checkout")))
      (should (= queries 0)))))

(ert-deftest cooked-completion-asks-again-when-the-answer-was-truncated ()
  "The reported bug: `pacman' is past the cap at `p', and no filtering finds it."
  (cooked-tests--with-stub-shell
      '(("pacman" . (6 0 nil ("pacman" "" "") ("pacman-key" "" ""))))
      queries
    (let ((table (cooked--completion-dynamic
                  "" "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                  ;; What the shell sent for `p': cut off before `pacman'.
                  '("p" t ("pacman-key" "" "")))))
      (should (equal (all-completions "pacman" table) '("pacman" "pacman-key")))
      (should (= queries 1)))))

(ert-deftest cooked-completion-asks-again-when-the-completion-changed-kind ()
  "`git checkout ' offers branches; a `-' makes it flags, which no branch matches."
  (cooked-tests--with-stub-shell
      '(("git checkout -" . (1 0 nil ("--track" "" "") ("--detach" "" ""))))
      queries
    (let ((table (cooked--completion-dynamic
                  "git checkout " "" (make-hash-table :test #'equal)
                  (make-hash-table :test #'equal)
                  '("" nil ("main" "" "") ("cache" "" "")))))
      (should (equal (all-completions "-" table) '("--track" "--detach")))
      (should (= queries 1)))))

(ert-deftest cooked-completion-keeps-the-last-answer-when-a-query-fails ()
  "A completer past the timeout must not empty the popup under the user."
  (cooked-tests--with-stub-shell '() queries
    (let ((table (cooked--completion-dynamic
                  "" "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                  '("p" t ("pacman-key" "" "")))))
      (should (equal (all-completions "pacman-k" table) '("pacman-key")))
      (should (= queries 1)))))

(ert-deftest cooked-completion-drops-a-reply-to-a-request-it-did-not-make ()
  "A completer slower than the timeout answers eventually; by then it is stale."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    ;; Through a real announcement, so the shell is reply-capable: setting the nonce
    ;; alone left `cooked--shell-completions' failing its guard a clause early, and
    ;; nothing downstream of it -- including the serial comparison this test is about --
    ;; ever ran.
    (cooked--osc-emacs '("CH;2;1234;1"))
    ;; And ZLE has to be the thing reading, or the request stops at that clause instead
    ;; and the wait below never runs.  A bare `cat' sends no OSC 133, so `cooked--semantic'
    ;; is nil here until it is told otherwise.
    (cooked--handle-semantic '(prompt-end (screen 0 . 0)) nil)
    (should (eq cooked--semantic 'input))
    (let ((cooked-completion-timeout 0.05))
      ;; Injected as the request goes out rather than before it.  A reply seeded ahead of
      ;; the call was cleared by `cooked--shell-completions' on entry, so the serial was
      ;; never compared against anything; the stale answer has to be standing while the
      ;; wait is running, which is also what actually happens to a slow completer.
      (cl-letf (((symbol-function 'cooked--send-if-live)
                 (lambda (&rest _)
                   (cooked--completion-handle
                    (cooked-tests--completion-reply
                     (1- cooked--completion-serial) 0 '(("stale" "" "")))))))
        (should-not (cooked--shell-completions "wha" 3))))))

(ert-deftest cooked-completion-asks-nobody-without-an-announcement ()
  "The trigger is only a keystroke: to a shell with no widget bound to it, the
request is a line of input.  Nothing is sent until the shell says it is listening."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (should-not (cooked-line-completion-nonce (cooked--line)))
    (should-not (cooked--shell-completions "git chec" 8))
    ;; And the CAPF still completes, in Emacs.
    (goto-char cooked--input-end)
    (insert "ls")
    (pcase-let ((`(,_start ,_end ,table . ,_) (cooked-completion-at-point)))
      (should (member "ls" (all-completions "ls" table))))))

(ert-deftest cooked-completion-asks-nothing-once-the-shell-runs-something ()
  "Once a command is running, those bytes would land in it rather than in ZLE.

The core forgets the nonce at `command-start' -- `cooked-completion-nonce-does-not-outlive-its-prompt'
covers that -- so this is the second of the two guards rather than the only one:
the question is asked again at the moment of sending, against a nonce that is
somehow still standing.  It is the sharper one.  With `zsh' running a canonical
reader like `cat', the termios mode is `cooked' and the policy stays `cooked'
too, so nothing about keyboard ownership notices that ZLE has stopped reading.

The announcement is therefore replayed *after* the command starts, which is the
only way to reach that guard now: an announcement made before it is cleared by
it, and the request then stops for the missing nonce without ever asking the
question this test is named for."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (cooked--handle-semantic '(command-start nil (screen 0 . 0)) nil)
    (should (eq cooked--semantic 'output))
    (cooked--osc-emacs '("CH;2;abcd;1"))
    (should (equal (cooked-line-completion-nonce (cooked--line)) "abcd"))
    ;; Ownership has *not* changed, which is the case this covers.
    (should (cooked--input-state-p))
    (let (sent)
      (cl-letf (((symbol-function 'cooked--send-if-live)
                 (lambda (&rest _) (setq sent t))))
        (should-not (cooked--shell-completions "git chec" 8))
        (should-not sent)))))

(ert-deftest cooked-completion-comes-from-zsh-itself ()
  "The whole exchange against a real shell: zsh's own completion system, run in
the shell you are typing at, over a line it has never seen."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "autoload -Uz compinit\ncompinit -u -d $ZDOTDIR/zcompdump\nPS1='%% '\n"))
    (cooked-tests--with-shell
        ("zsh"
         :name "*cooked-complete*"
         :directory (file-name-directory (directory-file-name cooked--source-directory))
         ;; The nonce is the shell saying its widget is bound and ZLE is reading.
         :settle (lambda () (and (cooked--input-start-position) (cooked-line-completion-nonce (cooked--line)))))
      (goto-char cooked--input-end)
      (insert "cd shell-int")
      (let ((before (cooked-tests--text))
            (cooked-completion-timeout 5))
        (cooked-completion-at-point)
        ;; The line briefly lives in ZLE, which redraws from it when the widget
        ;; returns.  Putting it back byte for byte is what keeps that redraw a
        ;; no-op; anything else shows up here as the screen having changed.
        (cooked-tests--settle (lambda () nil) 0.3)
        (should (equal (cooked-tests--text) before)))
      (let ((cooked-completion-timeout 5))
        (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
          ;; Only the word is replaced, and only the directory is offered.
          ;; Emacs would have offered the files too: knowing that `cd' takes a
          ;; directory is the shell's knowledge, not ours.
          (should (equal (buffer-substring-no-properties start end) "shell-int"))
          (should (equal (all-completions "shell-int" table) '("shell-integration")))))
      ;; A path is completed against its own directory, and the candidate comes
      ;; back carrying the components compsys walked past to reach it.
      (delete-region (cooked--input-start-position) (point))
      (insert "cat shell-integration/cooked.z")
      (let ((cooked-completion-timeout 5))
        (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
          (should (equal (buffer-substring-no-properties start end)
                         "shell-integration/cooked.z"))
          (should (equal (all-completions "shell-integration/cooked.z" table)
                         '("shell-integration/cooked.zsh")))))
      ;; The table is asked again for each word typed into it, rather than
      ;; filtered in Emacs.  Nothing else can pass this: the first answer is a
      ;; list of file names, and no amount of filtering turns that into flags.
      (let ((cooked-completion-timeout 5))
        (delete-region (cooked--input-start-position) (point))
        (insert "ls ")
        (pcase-let ((`(,_start ,_end ,table . ,_) (cooked-completion-at-point)))
          (should (member "README.org" (all-completions "" table)))
          (should (equal (all-completions "--colo" table) '("--color"))))))))

(ert-deftest cooked-completion-survives-a-configured-compsys ()
  "The same exchange against a zsh configured the way people configure zsh.

Every other zsh test here runs a stock compsys, where matching happens to be by
prefix and the candidates happen to extend the word -- which is precisely the
condition that let this break unnoticed.  Two settings out of an ordinary
`.zshrc' are enough to leave it:

  `matcher-list m:{a-zA-Z}={A-Za-z}'  folds case, so `RE' offers `README.org'
  `completer ... _expand ...'         offers `$PWD/x' as the path it expands to

Neither candidate begins with the text it replaces.  Before the `cooked-shell'
style they were both filtered out again between the shell and the popup, which
reached the user as a popup that came back empty and as candidates that could
not be accepted."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "autoload -Uz compinit\ncompinit -u -d $ZDOTDIR/zcompdump\n\
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'\n\
zstyle ':completion:*' completer _expand _complete\n\
PS1='%% '\n"))
    (cooked-tests--with-shell
        ("zsh"
         :name "*cooked-complete-configured*"
         :directory (file-name-directory (directory-file-name cooked--source-directory))
         :settle (lambda () (and (cooked--input-start-position)
                                 (cooked-line-completion-nonce (cooked--line)))))
      (goto-char cooked--input-end)
      ;; Case folded by the matcher: the candidate replaces `RE', it does not
      ;; extend it.
      (insert "cat RE")
      (let ((cooked-completion-timeout 5))
        (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
          (should (equal (buffer-substring-no-properties start end) "RE"))
          (should (member "README.org" (all-completions "RE" table)))))
      ;; And the answer stays whole as the word grows, which is the half that
      ;; filtering in Emacs used to take away.
      (insert "A")
      (let ((cooked-completion-timeout 5))
        (pcase-let ((`(,_start ,_end ,table . ,_) (cooked-completion-at-point)))
          (should (member "README.org" (all-completions "REA" table)))))
      ;; `_expand' answers with the expansion of the word rather than a
      ;; completion of it, so its candidate shares no head with what was typed.
      ;; Both halves matter here.  The expansion has to survive at all -- Emacs
      ;; used to keep only `$PWD/READ', the one candidate that says nothing,
      ;; which is what a popup offering you back your own typing looked like.
      ;; And TAB must not rewrite the line to a head invented across the two.
      (delete-region (cooked--input-start-position) (point))
      (insert "cat $PWD/READ")
      (let ((cooked-completion-timeout 5))
        (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
          (let* ((word (buffer-substring-no-properties start end))
                 (all (all-completions word table)))
            (should (equal word "$PWD/READ"))
            (should (member (expand-file-name "READ" default-directory) all))
            ;; The one Emacs would have kept, and on its own it is no answer.
            (should (member word all))
            (should (equal (try-completion word table) word))))))))

(ert-deftest cooked-completion-mid-line-replaces-the-word-under-the-cursor ()
  "The span is anchored at the cursor the request was *sent* from.

zsh measures PREFIX against the cursor position it was handed, and the answer
comes back through a drain -- which lifts the pending input out of the buffer
and rebuilds it.  Reading point again afterwards therefore gives the right
length against the wrong anchor: a span reaching PREFIX characters back from
wherever the drain left point, which is why the report described it as
sometimes the next chunk and sometimes the whole prompt.  Here there is a word
after the cursor to make the difference visible."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "autoload -Uz compinit\ncompinit -u -d $ZDOTDIR/zcompdump\nPS1='%% '\n"))
    (cooked-tests--with-shell
        ("zsh"
         :name "*cooked-complete*"
         :directory (file-name-directory (directory-file-name cooked--source-directory))
         :settle (lambda () (and (cooked--input-start-position) (cooked-line-completion-nonce (cooked--line)))))
      (goto-char cooked--input-end)
      (insert "cat shell-int README.org")
      ;; Back onto the end of `shell-int', leaving ` README.org' after point.
      (goto-char (- (point) (length " README.org")))
      (let ((here (point))
            (cooked-completion-timeout 5))
        (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
          ;; Point is where the request was issued from, not at the end of
          ;; the line the drain rebuilt.
          (should (= (point) here))
          (should (= end here))
          (should (equal (buffer-substring-no-properties start end) "shell-int"))
          (should (equal (all-completions "shell-int" table)
                         '("shell-integration")))))
      ;; And the rest of the line is untouched by any of it.
      (should (equal (cooked--pending-input) "cat shell-int README.org")))))

(ert-deftest cooked-completion-comes-from-bash-itself ()
  "The same exchange against bash, over the same wire.

bash needs none of zsh's ZLE gymnastics -- `complete -p' names the registered
function and it can be invoked directly -- so the whole capture is bookkeeping.
What is worth testing is that it is the *same* bookkeeping: one Emacs-side
parser, one protocol, and a shell that announces for itself.

The spec here is registered by the test rather than borrowed from
bash-completion, which is not installed everywhere and would make this a test of
somebody else's package."
  :tags '(base64 bash)
  (skip-unless (executable-find "bash"))
  (skip-unless (executable-find "base64"))
  (let ((buffer (generate-new-buffer "*cooked-bash-complete*"))
        (home (make-temp-file "cooked-bash-home-" t)))
    (with-temp-file (expand-file-name ".bashrc" home)
      (insert "PS1='$ '\n"
              "_mytool() { COMPREPLY=( $(compgen -W \"alpha beta gamma\" -- \"$2\") ); }\n"
              "complete -F _mytool mytool\n"))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          ;; The real HOME is *removed* rather than shadowed by a second entry:
          ;; which of two entries for one name reaches the child is not a thing to
          ;; depend on, and getting it wrong here means the shell reads the
          ;; developer's own .bashrc and completes against whatever that defines.
          ;; `default-directory' moves with it, since it is stored abbreviated and a
          ;; `~/...' would otherwise resolve against the fake home.
          (let ((default-directory (file-name-as-directory home))
                (process-environment
                 (cons (concat "HOME=" home)
                       (seq-remove (lambda (entry) (string-prefix-p "HOME=" entry))
                                   process-environment))))
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "bash"))))
              (setq cooked--scratch scratch)
              ;; An explicit directory: HOME is redirected for this shell, and a
              ;; `default-directory' that abbreviates to ~ would resolve against the
              ;; fake one.
              (cooked--start argv home env)))
          (cooked--refresh-keymap)
          ;; The announcement is the shell saying a line editor is reading and that
          ;; this one can also answer.
          (should (cooked-tests--settle
                   (lambda () (and (cooked--input-start-position)
                                   (cooked-line-completion-nonce (cooked--line))
                                   (cooked-line-completion-reply-capable (cooked--line))))
                   10))
          (let ((cooked-completion-timeout 5))
            (pcase-let ((`(,prefix ,_suffix ,_truncated . ,records)
                         (cooked--shell-completions "mytool a" 8)))
              ;; Only the word being completed is replaced.
              (should (= prefix 1))
              (should (equal (mapcar #'car records) '("alpha")))))
          (let ((cooked-completion-timeout 5))
            (pcase-let ((`(,prefix ,_suffix ,_truncated . ,records)
                         (cooked--shell-completions "mytool " 7)))
              (should (= prefix 0))
              (should (equal (mapcar #'car records) '("alpha" "beta" "gamma"))))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer)
      (delete-directory home t))))

(ert-deftest cooked-completion-completes-the-second-line-of-a-request ()
  "A line submitted with `cooked-newline' carries its newline into the request.

Two things used to lose it.  The decoder built its answer a byte at a time
through `out+=$(printf ...)', and `$(...)' strips a trailing newline, so `%0A'
decoded to nothing and the two lines arrived run together -- `ls\\nx' as `lsx'.
And the splitter read the line with a plain `read', which stops at the first
newline, so the word under the cursor was looked for among the words of the
first line.

The reply here can only be right if both are: `mytool' is on the second line and
its spec is the only thing in this shell that answers `alpha'."
  :tags '(base64 bash)
  (skip-unless (executable-find "bash"))
  (skip-unless (executable-find "base64"))
  (let ((buffer (generate-new-buffer "*cooked-bash-multiline*"))
        (home (make-temp-file "cooked-bash-home-" t)))
    (with-temp-file (expand-file-name ".bashrc" home)
      (insert "PS1='$ '\n"
              "_mytool() { COMPREPLY=( $(compgen -W \"alpha beta gamma\" -- \"$2\") ); }\n"
              "complete -F _mytool mytool\n"))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (let ((default-directory (file-name-as-directory home))
                (process-environment
                 (cons (concat "HOME=" home)
                       (seq-remove (lambda (entry) (string-prefix-p "HOME=" entry))
                                   process-environment))))
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "bash"))))
              (setq cooked--scratch scratch)
              (cooked--start argv home env)))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (and (cooked--input-start-position)
                                   (cooked-line-completion-nonce (cooked--line))
                                   (cooked-line-completion-reply-capable (cooked--line))))
                   10))
          (let ((line "echo hi\nmytool a")
                (cooked-completion-timeout 5))
            (pcase-let ((`(,prefix ,_suffix ,_truncated . ,records)
                         (cooked--shell-completions line (length line))))
              (should (= prefix 1))
              (should (equal (mapcar #'car records) '("alpha"))))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer)
      (delete-directory home t))))

(ert-deftest cooked-completion-runs-a-spec-its-loader-defers ()
  "bash-completion registers almost nothing per command.

It installs one `-D' default whose function sources `completions/CMD' on first
use and returns 124, which is bash's way of telling readline that a spec now
exists and the completion is worth attempting again.  Nobody tabs in readline
here, so the 124 is ours to honour or the spec is never loaded at all and `git
checkout ma' completes to file names.

The loader is a stub rather than upstream bash-completion, which is not installed
everywhere and would make this a test of somebody else's package.  It behaves the
way upstream's does in the three ways that matter: it registers per command only
when asked, it returns 124 either way, and it records every call so that a second
request can be shown *not* to reach it."
  :tags '(base64 bash)
  (skip-unless (executable-find "bash"))
  (skip-unless (executable-find "base64"))
  (let ((buffer (generate-new-buffer "*cooked-bash-lazy*"))
        (home (make-temp-file "cooked-bash-home-" t)))
    (with-temp-file (expand-file-name ".bashrc" home)
      (insert "PS1='$ '\n"
              "_cooked_stub_load() {\n"
              "  printf '%s\\n' \"$1\" >> \"$HOME/loads\"\n"
              "  [[ -r $HOME/completions/$1 ]] && source \"$HOME/completions/$1\"\n"
              "  return 124\n"
              "}\n"
              "complete -F _cooked_stub_load -D\n"))
    (make-directory (expand-file-name "completions" home))
    (with-temp-file (expand-file-name "completions/mytool" home)
      (insert "_mytool() { COMPREPLY=( $(compgen -W \"alpha beta gamma\" -- \"$2\") ); }\n"
              "complete -F _mytool mytool\n"))
    (with-temp-file (expand-file-name "landmark.txt" home) (insert ""))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (let ((default-directory (file-name-as-directory home))
                (process-environment
                 (cons (concat "HOME=" home)
                       (seq-remove (lambda (entry) (string-prefix-p "HOME=" entry))
                                   process-environment))))
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "bash"))))
              (setq cooked--scratch scratch)
              (cooked--start argv home env)))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (and (cooked--input-start-position)
                                   (cooked-line-completion-nonce (cooked--line))
                                   (cooked-line-completion-reply-capable (cooked--line))))
                   10))
          (cl-flet ((loads ()
                      (let ((file (expand-file-name "loads" home)))
                        (if (file-exists-p file)
                            (with-temp-buffer (insert-file-contents file) (buffer-string))
                          ""))))
            ;; Nothing is registered for `mytool', so the default runs, loads the
            ;; spec and asks for another attempt; the candidates come from the spec
            ;; it loaded.
            (let ((cooked-completion-timeout 5))
              (pcase-let ((`(,prefix ,_suffix ,_truncated . ,records)
                           (cooked--shell-completions "mytool a" 8)))
                (should (= prefix 1))
                (should (equal (mapcar #'car records) '("alpha")))))
            (should (equal (loads) "mytool\n"))
            ;; And the second request finds the spec registered, so the loader is
            ;; never reached again.
            (let ((cooked-completion-timeout 5))
              (pcase-let ((`(,_prefix ,_suffix ,_truncated . ,records)
                           (cooked--shell-completions "mytool b" 8)))
                (should (equal (mapcar #'car records) '("beta")))))
            (should (equal (loads) "mytool\n"))
            ;; A loader that defers and then registers nothing has to end somewhere,
            ;; and it ends in file names rather than in another attempt.
            (let ((cooked-completion-timeout 5))
              (pcase-let ((`(,_prefix ,_suffix ,_truncated . ,records)
                           (cooked--shell-completions "notool land" 11)))
                (should (equal (mapcar #'car records) '("landmark.txt")))))
            (should (equal (loads) "mytool\nnotool\n"))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer)
      (delete-directory home t))))

(ert-deftest cooked-completion-comes-from-fish-itself ()
  "The same exchange against fish, over the same wire.

fish needs neither of the other two shells' tricks: `complete --do-complete'
takes a line as a string, completes it from any context, and prints each
candidate with its description.  What is worth testing is that it is the *same*
exchange -- one protocol, one Emacs-side parser -- and that the capture reaches
the child at all, since it gets there through the `vendor_conf.d' snippet
`cooked--shell-invocation' generates rather than through anything this test
writes.

`git checkout ma' is the case the review drove by hand, and it is the one that
cannot be answered by anything but the shell: `main' is a branch, not a file, and
the description comes back with it."
  :tags '(base64 fish git)
  (skip-unless (executable-find "fish"))
  (skip-unless (executable-find "base64"))
  (skip-unless (executable-find "git"))
  (let ((root (file-name-directory (directory-file-name cooked--source-directory))))
    (cooked-tests--with-shell
        ("fish"
         :name "*cooked-fish-complete*"
         :directory root
         ;; The announcement is the shell saying its binding is in place and that
         ;; this one can also answer.
         :settle (lambda () (and (cooked--input-start-position)
                                 (cooked-line-completion-nonce (cooked--line))
                                 (cooked-line-completion-reply-capable (cooked--line))))
         :timeout 10)
      (let ((cooked-completion-timeout 5))
        (pcase-let ((`(,prefix ,_suffix ,_truncated . ,records)
                     (cooked--shell-completions "git checkout ma" 15)))
          ;; Only the word under the cursor is replaced.
          (should (= prefix 2))
          (should (member "main" (mapcar #'car records)))
          ;; And it arrives with fish's description, in the shape compsys sends one,
          ;; so the one parser reads all three shells.
          (should (string-prefix-p "main -- " (cadr (assoc "main" records))))))
      ;; A path is completed against the tree this test is running in, and fish
      ;; answers with the whole token rather than its last component -- which is
      ;; what makes the span the token and not the file name.
      (let ((cooked-completion-timeout 5))
        (pcase-let ((`(,prefix ,_suffix ,_truncated . ,records)
                     (cooked--shell-completions "cat shell-integration/cooked.f" 30)))
          (should (= prefix 26))
          (should (equal (mapcar #'car records)
                         '("shell-integration/cooked.fish"))))))))

(ert-deftest cooked-completion-without-the-layer-stays-in-emacs ()
  "Unloaded, the layer is idle but the announcement is still heard.

The two halves come apart here.  A request is this layer's business, so with
both seams nil nothing leaves Emacs and the CAPF answers from its own table.
The *announcement* is not: `cooked--policy' reads it as a license to own the
input line, and a session that never loads this file needs that reading as much
as one that does -- so the nonce is kept regardless of who is listening for
replies."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (let ((cooked-osc-completion-functions nil)
          (cooked-shell-completion-functions nil)
          (sent nil))
      ;; Believed with no layer loaded: this is an ownership signal, not a
      ;; completion one.
      (cooked--osc-emacs '("CH;2;1234;1"))
      (should (equal (cooked-line-completion-nonce (cooked--line)) "1234"))
      (should (cooked-line-completion-reply-capable (cooked--line)))
      ;; And the CAPF still answers from Emacs without sending anything.
      (cl-letf (((symbol-function 'cooked--send-if-live)
                 (lambda (&rest _) (setq sent t))))
        (goto-char cooked--input-end)
        (insert "ls")
        (pcase-let ((`(,start ,_end ,table . ,_) (cooked-completion-at-point)))
          (should (= start (cooked--input-start-position)))
          (should (member "ls" (all-completions "ls" table)))))
      (should-not sent))))

(ert-deftest cooked-completion-announcement-carries-a-reply-capability ()
  "Framing a reply needs `base64'; owning the input line does not.

A shell without it announces anyway and says so in the last field, so it keeps
its editable line and merely has nothing to offer `completion-at-point'.
Snippets predating the field could only announce when they could also reply, so
their silence reads as capable."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (cooked--osc-emacs '("CH;2;1234;1"))
    (should (equal (cooked-line-completion-nonce (cooked--line)) "1234"))
    (should (cooked-line-completion-reply-capable (cooked--line)))
    (cooked--osc-emacs '("CH;2;5678;0"))
    (should (equal (cooked-line-completion-nonce (cooked--line)) "5678"))
    (should-not (cooked-line-completion-reply-capable (cooked--line)))
    (cooked--osc-emacs '("CH;2;9012"))
    (should (equal (cooked-line-completion-nonce (cooked--line)) "9012"))
    (should (cooked-line-completion-reply-capable (cooked--line)))
    ;; A version we do not speak is a shell failing to make a claim, and the safe
    ;; reading of no claim is no license.
    (cooked--osc-emacs '("CH;3;3456;1"))
    (should-not (cooked-line-completion-nonce (cooked--line)))))

(ert-deftest cooked-completion-nonce-does-not-outlive-its-prompt ()
  "`ssh host' must not leave the local shell's license standing.

The announcement is a claim about the line being read now.  Once a command
starts, whatever it spawns -- a remote shell, a nested `zsh -f', a REPL --
announces for itself or does not announce at all; inheriting the old nonce would
hand a bare remote prompt a license nothing on that host ever issued."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (cooked--osc-emacs '("CH;2;1234;1"))
    (should (equal (cooked-line-completion-nonce (cooked--line)) "1234"))
    (cooked--handle-semantic '(command-start nil (screen 0 . 0)) nil)
    (should-not (cooked-line-completion-nonce (cooked--line)))
    (should-not (cooked-line-completion-reply-capable (cooked--line)))))

(ert-deftest cooked-a-command-starting-forgets-everything-said-about-the-line ()
  "Every field of `cooked-line' ends with the line, not only the nonce.

A delegated line, a continuation prompt, a submission waiting for its mark and an
announcement are all claims about the line just typed.  `command-start' drops the
record whole, so a field added later is cleared there by construction; this
fills every slot first so a record that kept one would fail here."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (let ((record (cooked--line)))
      (setf (cooked-line-delegated record) t
            (cooked-line-completion-nonce record) "1234"
            (cooked-line-completion-reply-capable record) t
            (cooked-line-prompt-continued record) t
            (cooked-line-submitted-input record) "echo hi"))
    (cooked--handle-semantic '(command-start nil (screen 0 . 0)) nil)
    (should (equal cooked--command-input "echo hi"))
    (should (equal (cooked--line) (cooked--line-make)))))

(ert-deftest cooked-completion-layer-decides-what-the-shell-is-told ()
  "The zsh capture cannot retract a `compadd' shadow, so whether to install one
is decided when the child starts, from whether the layer was loaded by then.

It used to travel as COOKED_COMPLETION in the environment.  That was only ever a
longer way of saying this: the startup file is written at spawn too, so writing
the `source' line or not makes the same decision at the same moment, with one
fewer variable to explain.  The core snippet is sourced either way -- it is what
the marks and the announcement come from, and neither is optional."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (dolist (loaded '(nil t))
    (let ((cooked-shell-completion-functions
           (and loaded (list #'cooked--shell-completion-at-point))))
      (pcase-let ((`(,_argv ,_env ,scratch)
                   (cooked--shell-invocation (executable-find "zsh"))))
        (unwind-protect
            (let ((rc (with-temp-buffer
                        (insert-file-contents (expand-file-name ".zshrc" scratch))
                        (buffer-string))))
              (should (string-match-p "cooked\\.zsh" rc))
              (should (eq (and (string-match-p "cooked-completion\\.zsh" rc) t)
                          loaded)))
          (when scratch (delete-directory scratch t)))))))

(ert-deftest cooked-completion-that-lists-nothing-leaves-no-copy-of-the-line ()
  "A completer with nothing to offer used to paint the line onto the screen.

compsys refreshes the display itself on the way to a message or a beep, and the
line it draws is the one the capture put in BUFFER -- so a second copy of the
command appeared exactly where the completion would have gone, and restoring
BUFFER did not take it back.  `git commit -am <TAB>' is the everyday case: the
flags have already said everything, so `_git' offers nothing and explains why."
  :tags '(git zsh)
  (skip-unless (executable-find "zsh"))
  (skip-unless (executable-find "git"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "autoload -Uz compinit\ncompinit -u -d $ZDOTDIR/zcompdump\nPS1='%% '\n"))
    (cooked-tests--with-shell
        ("zsh"
         :name "*cooked-complete*"
         :directory (file-name-directory (directory-file-name cooked--source-directory))
         :settle (lambda () (and (cooked--input-start-position) (cooked-line-completion-nonce (cooked--line)))))
      (goto-char cooked--input-end)
      (insert "git commit -am ")
      (let ((before (cooked-tests--text))
            (cooked-completion-timeout 5))
        ;; An answer arrived and it is empty -- (PREFIX SUFFIX TRUNCATED),
        ;; with no records behind it -- which is the case this is about.
        (should-not (nthcdr 3 (cooked--shell-completions "git commit -am " 15)))
        ;; Asserted the moment the reply lands, not after the dust settles: the
        ;; repair travels ahead of the reply, so there is no drain that can see
        ;; the answer and still be showing the copy.
        (should (equal (cooked-tests--text) before))
        (cooked-tests--settle (lambda () nil) 0.3)
        (should (equal (cooked-tests--text) before))))))

(ert-deftest cooked-completion-withholds-the-screen-while-the-shell-works ()
  "And the copy must not be rendered even for the instant before it is erased.

The repair travels ahead of the reply, so the *settled* screen is clean -- which
is what the test above asserts, and it is not the whole story.  A drain landing
between compsys' refresh and the widget's repair renders the copy and the next
one takes it away again, which reached the user as the command flickering
doubled under the prompt for as long as a drain interval.

Nothing after the fact can close that window, because the window is the point.
So the screen is withheld for the length of the exchange: drains still run --
the reply is an event and would otherwise never arrive -- but they leave the
rows alone, and the whole drain that follows renders the repaired prompt
straight from the shell's own corrected screen.  Asserted through the argument
`cooked--on-wake' passes rather than by watching for a flicker, a race being a
poor thing to assert on: every wake taken while the request was outstanding has
to have been a withheld one."
  :tags '(git zsh)
  (skip-unless (executable-find "zsh"))
  (skip-unless (executable-find "git"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "autoload -Uz compinit\ncompinit -u -d $ZDOTDIR/zcompdump\nPS1='%% '\n"))
    (cooked-tests--with-shell
        ("zsh"
         :name "*cooked-complete-flicker*"
         :directory (file-name-directory (directory-file-name cooked--source-directory))
         :settle (lambda () (and (cooked--input-start-position)
                                 (cooked-line-completion-nonce (cooked--line)))))
      (goto-char cooked--input-end)
      (insert "git commit -am 'Some")
      (let* ((before (cooked-tests--text))
             (cooked-completion-timeout 5)
             (withheld nil)
             (original (symbol-function 'cooked--drain-and-repair)))
        (cl-letf (((symbol-function 'cooked--drain-and-repair)
                   (lambda (hidden &rest rest)
                     (push (and hidden t) withheld)
                     (apply original hidden rest))))
          (cooked--shell-completions "git commit -am 'Some" 20))
        ;; The shell answered, so at least one wake happened inside the request.
        (should withheld)
        (should (seq-every-p #'identity withheld))
        ;; The claim is the request's, not the session's.
        (should-not (memq 'completion cooked--screen-held-by))
        ;; And the debt it left has been paid: the prompt on screen is the
        ;; repaired one, with no second copy of the command anywhere in it.
        (should (equal (cooked-tests--text) before))
        (cooked-tests--settle (lambda () nil) 0.3)
        (should (equal (cooked-tests--text) before))
        (should-not (cooked--screen-debt))))))

(ert-deftest cooked-a-redisplay-during-a-request-draws-no-copy-of-the-line ()
  "And the withheld drain is only half of what keeps it off the screen.

The test above asserts what `cooked--on-wake' is *passed*, which is why this
survived two spellings of the flags: the drain does leave the rows alone, and
then `cooked--sync-before-redisplay' sees a debt and drains them whole anyway.
`accept-process-output' -- the one thing the request blocks in -- redisplays
while it waits, so that hook fires in the middle of every request there is
anything to wait for, and what it renders is the copy withholding exists to
hide.  So the debt is refused while a `completion' claim stands; see
`cooked--screen-kept-still-p'.

Watching a real shell for a flicker is the race the test above declined to
assert on, and none of this needs one.  The copy is put on the emulator's grid
with `cooked--feed', which wakes nobody, so the intermediate state arrives at a
moment this test picks; the wait is stubbed, so the redisplay happens at a
moment this test picks; and the frame is a real tty one, so `redisplay' really
runs and the hook really fires.

Both halves are here.  The screen does not gain the copy while the claim
stands, and a reader calling `cooked--sync' meanwhile is answered from the same
pre-request rows -- then the release drains whole and the copy appears, because
refusing the debt defers it rather than dropping it."
  (cooked-tests--with-tty-frame
    (cooked-tests--with-session
        ;; Echo off and stdin never read, so nothing the request writes comes
        ;; back: every byte this buffer's emulator sees is one fed below, at a
        ;; point of this test's choosing.  The marker is how the test knows
        ;; `stty' has run before it sends anything.
        '("/bin/sh" "-c" "stty -echo; printf ready; exec sleep 60")
      (should (cooked-tests--settle
               (lambda () (string-match-p "ready" (cooked-tests--text)))))
      (set-window-buffer (frame-root-window) (current-buffer))
      (cooked--window-buffers-changed)
      ;; The line as the user typed it, and one redisplay to settle the window
      ;; on it, so that what `before' holds is what a further redisplay draws.
      (cooked--feed cooked--session "\r\n$ git commit -am 'Some")
      (cooked--drain-and-apply)
      (redisplay t)
      (cl-flet ((copies ()
                  (cl-loop with text = (cooked-tests--text)
                           with at = 0 with seen = 0
                           while (setq at (string-search "git commit -am 'Some"
                                                         text at))
                           do (cl-incf seen) (cl-incf at)
                           finally return seen)))
        (let ((before (cooked-tests--text))
              (during nil)
              (reader nil)
              (cooked--semantic 'input))
          (should (= (copies) 1))
          (setf (cooked-line-completion-nonce (cooked--line)) "nonce"
                (cooked-line-completion-reply-capable (cooked--line)) t)
          (cl-letf (((symbol-function 'accept-process-output)
                     (lambda (&rest _)
                       ;; compsys' refresh: the line Emacs is holding, drawn a
                       ;; second time under the prompt on its way to a beep.
                       (cooked--feed cooked--session "\r\ngit commit -am 'Some")
                       (redisplay t)
                       (setq during (cooked-tests--text))
                       ;; The other half: a reader that asks mid-request.
                       (cooked--sync)
                       (setq reader (cooked-tests--text))
                       ;; Answer this request, so the wait ends here.
                       (setq cooked--completion-reply
                             (list cooked--completion-serial 0 0 nil)))))
            (should (equal (cooked--shell-completions "git commit -am 'Some" 20)
                           '(0 0 nil))))
          (should (equal during before))
          (should (equal reader before))
          ;; Released, and the drain the release makes pays what was refused.
          (should-not (memq 'completion cooked--screen-held-by))
          (should-not (cooked--screen-debt))
          (should (= (copies) 2)))))))

(ert-deftest cooked-completion-gives-the-screen-back-when-a-request-quits ()
  "C-g out of a shell that stopped talking must not leave the screen held.

A `completion' claim left standing -- see `cooked--screen-held-by' -- is a
terminal that never repaints again, which is a far worse outcome than the
flicker it was taken to prevent, so it is released on the way out however the
exchange ends."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (cl-letf (((symbol-function 'accept-process-output)
               (lambda (&rest _) (signal 'quit nil))))
      (let ((cooked-completion-timeout 5))
        ;; The nonce is what licenses a request at all; without one nothing is
        ;; sent and the flag is never reached.
        (setf (cooked-line-completion-nonce (cooked--line)) "nonce"
              (cooked-line-completion-reply-capable (cooked--line)) t)
        ;; `with-local-quit' lets the cleanup run and then re-signals, which is
        ;; the behaviour under test: C-g leaves the request, and the screen
        ;; comes back with it.
        (let ((cooked--semantic 'input))
          (should-not (condition-case nil
                          (cooked--shell-completions "ls" 2)
                        (quit nil))))))
    (setq quit-flag nil)
    (should-not (memq 'completion cooked--screen-held-by))))

;;;; Candidates the shell matched by a rule Emacs does not have
;;
;; compsys is not matching by prefix, and every test below is one way of finding
;; that out.  A stock `matcher-list' folds case; `_expand' answers `$HOME/sr'
;; with `/home/simon/sr'; `_approximate' answers a misspelling with the
;; correction.  Handed to an ordinary table, none of those candidates survives
;; the filtering `completion-in-region' does on the way to the popup -- which is
;; the bug this section exists to hold shut, reported as a popup that came back
;; empty and as candidates that could be seen but not accepted.

(ert-deftest cooked-completion-keeps-what-the-shell-already-matched ()
  "A case-folded answer is the shell's to make, and Emacs must not overrule it.

`zstyle :completion:* matcher-list m:{a-zA-Z}={A-Za-z}' is what makes `Pac'
offer `pacman'.  Every candidate here replaces the span rather than extending
it, so prefix filtering -- which is what `completion-in-region' does by default
-- removes the entire answer and leaves nothing to choose from."
  (cooked-tests--with-stub-shell '() _queries
    (let* ((records '(("pacman" "" "") ("pacman-key" "" "") ("paclist" "" "")))
           (table (cooked--completion-dynamic
                   "" "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                   `("Pac" nil . ,records))))
      (should (equal (all-completions "Pac" table)
                     '("pacman" "pacman-key" "paclist")))
      ;; And through the styles, which is the path the popup actually takes:
      ;; `cooked-shell' is registered for the table's category and answers first.
      (should (equal (seq-take (completion-all-completions "Pac" table nil 3) 3)
                     '("pacman" "pacman-key" "paclist"))))))

(ert-deftest cooked-completion-asks-again-when-the-shell-did-not-match-by-prefix ()
  "Narrowing in Emacs is licensed by the answer, not assumed of it.

The shell offered `pacman' for `Pac', so for this completion it is matching by
something other than prefix and Emacs has no way to reproduce it.  Growing the
word therefore has to be a round trip: filtering the list in hand would drop
every candidate, which is exactly the reported \"as I type I am refining this
subset rather than requerying\"."
  (cooked-tests--with-stub-shell
      '(("Pacm" . (4 0 nil ("pacman" "" "") ("pacman-key" "" ""))))
      queries
    (let ((table (cooked--completion-dynamic
                  "" "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                  '("Pac" nil ("pacman" "" "") ("pacman-key" "" "") ("paclist" "" "")))))
      (should (equal (all-completions "Pacm" table) '("pacman" "pacman-key")))
      (should (= queries 1)))))

(ert-deftest cooked-completion-narrows-a-prefix-answer-without-asking ()
  "The licence is real, though: an answer that did match by prefix is narrowed here.

The fast path, and the reason the round trip is not simply made on every
keystroke -- a completer that takes 200ms is one that stutters if it is."
  (cooked-tests--with-stub-shell '() queries
    (let ((table (cooked--completion-dynamic
                  "" "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                  '("pac" nil ("pacman" "" "") ("pacman-key" "" "") ("paclist" "" "")))))
      (should (equal (all-completions "pacm" table) '("pacman" "pacman-key")))
      (should (= queries 0)))))

(ert-deftest cooked-completion-does-not-insert-a-head-it-invented ()
  "`_expand' offers the expansion; its common head is not the user's text.

Completing `$HOME/sr' offers `/home/simon/sr' alongside the word itself.  The
two share no head with what was typed, and `try-completion' over candidates
that replace the span must therefore hand the string back untouched rather than
rewrite the line to something nobody asked for."
  (cooked-tests--with-stub-shell '() _queries
    (let ((table (cooked--completion-dynamic
                  "cat " "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                  '("$HOME/sr" nil ("/home/simon/sr" "" "") ("$HOME/sr" "" "")))))
      (should (equal (try-completion "$HOME/sr" table) "$HOME/sr"))
      (should (equal (all-completions "$HOME/sr" table)
                     '("/home/simon/sr" "$HOME/sr")))
      ;; One candidate and it is not the string: that one *is* worth inserting.
      (should (equal (completion-try-completion "$HOME/sr" table nil 8)
                     '("$HOME/sr" . 8))))))

(ert-deftest cooked-completion-sole-candidate-replaces-the-span ()
  "`_approximate' corrects a misspelling, and accepting the correction is the point."
  (cooked-tests--with-stub-shell '() _queries
    (let ((table (cooked--completion-dynamic
                  "cat " "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                  '("shel-integration/cooked.z" nil
                    ("shell-integration/cooked.zsh" "" "")))))
      (should (equal (try-completion "shel-integration/cooked.z" table)
                     "shell-integration/cooked.zsh"))
      (should (equal (completion-try-completion "shel-integration/cooked.z" table nil 25)
                     (cons "shell-integration/cooked.zsh" 28))))))

(ert-deftest cooked-completion-both-appends-rather-than-falls-back ()
  "`both' means both, which `completion-table-in-turn' never did.

It stops at the first table that answers, so Emacs' candidates were reached
only when the shell had none -- which is what `shell' already does."
  (cooked-tests--with-stub-shell '() _queries
    (let* ((cooked-completion-backend 'both)
           (cooked--executables '("pacman-mirrors"))
           (table (cooked--completion-dynamic
                   "" "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                   '("pacman" nil ("pacman" "" "") ("pacman-key" "" ""))))
           (all (all-completions "pacman" table)))
      (should (member "pacman-key" all))
      (should (member "pacman-mirrors" all)))))

(ert-deftest cooked-completion-limit-reaches-the-shell ()
  "`cooked-completion-limit' is the shell's cap, so it has to get there."
  (let ((cooked-completion-limit 4242)
        (cooked-shell-integration 'detect))
    (pcase-let ((`(,_argv ,env ,scratch) (cooked--shell-invocation "/bin/zsh")))
      (unwind-protect
          (should (equal (cdr (assoc "COOKED_COMPLETE_LIMIT" env)) "4242"))
        (when scratch (delete-directory scratch t))))))

(ert-deftest cooked-completion-is-a-normal-capf ()
  "So corfu, cape and friends work without knowing about cooked."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (should (memq #'cooked-completion-at-point completion-at-point-functions))
    (should (eq (lookup-key cooked-input-map (kbd "TAB")) #'completion-at-point))))

(ert-deftest cooked-completion-declines-outside-the-input-line ()
  "Raw-mode programs get their own TAB; we must not complete over them."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (should-not (cooked-completion-at-point))))

(provide 'cooked-tests-completion)
;;; cooked-tests-completion.el ends here
