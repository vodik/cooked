;;; cooked-tests-osc-context.el --- OSC 3008 contexts in the mode line -*- lexical-binding: t; -*-

;;; Commentary:

;; `run0' needs polkit and a password, so no test here can run the real thing.
;; The sequences are instead spelled the way systemd 261's `osc-context.c'
;; spells them -- the format strings are readable in libsystemd-shared with
;; `strings', and the field order below is theirs -- and the stock bash prompt
;; snippet's `shell' and `command' contexts are replayed around them, because
;; that is the stack a real `run0 bash' lands on.  Most tests drive the handler
;; directly, as the OSC 9;4 tests do: what is under test is a state machine, and
;; a child can only show it one path at a time.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-osc-context)

(defconst cooked-tests--context-common
  (concat ";user=simon;hostname=ryzen"
          ";machineid=3deb5353d3ba43d08201c136a47ead7b"
          ";bootid=d4a3d0fdf2e24fdea6d971ce73f4fbf2"
          ";pid=4242;pidfdid=4243;comm=run0")
  "The fields systemd's `osc_context_intro' puts before the type, on this host.")

(defun cooked-tests--context (&rest payloads)
  "Feed each of PAYLOADS, a raw OSC 3008 payload string, to the handler.
Split on `;' as the core splits it.  Returns the resulting stack."
  (dolist (payload payloads)
    (cooked--handle-osc 3008 nil (split-string payload ";")))
  cooked-osc-context--stack)

(defun cooked-tests--context-shown ()
  "The context segment as the mode line prints it, `%%' undone.
By hand rather than through `format-mode-line', which answers the empty string
for everything in batch, where there is no mode line to format for."
  (string-replace "%%" "%" (or (cooked-osc-context--mode-line) "")))

(ert-deftest cooked-osc-context-requiring-the-file-wires-it ()
  "Requiring the file is the whole of opting in: the handler, and the segment in
every cooked buffer's mode line, placed ahead of cooked's own."
  (should (eq (alist-get 3008 cooked-osc-handlers) #'cooked-osc-context--handle))
  (with-temp-buffer
    (cooked-mode)
    (should (equal (car mode-line-process) cooked-osc-context--segment))
    ;; Idempotent, so a second run of the mode hook does not stack two copies.
    (cooked-osc-context--setup)
    (should (equal (cadr mode-line-process) '(:eval (cooked--mode-line))))))

(ert-deftest cooked-osc-context-run0-marks-the-mode-line-and-exit-clears-it ()
  "The Done-when line, replayed: `run0 bash' at a stock systemd bash prompt."
  (with-temp-buffer
    (cooked-mode)
    (let ((shell "start=11111111111111111111111111111111;type=shell;cwd=/home/simon")
          (command "start=22222222222222222222222222222222;type=command;cwd=/home/simon")
          (run0 (concat "start=33333333333333333333333333333333"
                        cooked-tests--context-common ";type=elevate")))
      (cooked-tests--context shell command run0)
      (should (equal (mapcar #'cdr cooked-osc-context--stack) '(elevate command shell)))
      (should (equal (cooked-tests--context-shown) " root"))
      (should (eq (get-text-property 1 'face (cooked-osc-context--mode-line))
                  'cooked-osc-context-elevate))
      ;; And ahead of cooked's own segment, as the construct the mode line reads.
      (should (equal (mapcar (lambda (form) (eval (cadr form) t)) mode-line-process)
                     (list (cooked-osc-context--mode-line) (cooked--mode-line))))
      ;; Inner contexts do not hide it: a root shell's own prompt contexts.
      (cooked-tests--context "start=44444444444444444444444444444444;type=shell;cwd=/root")
      (should (equal (cooked-tests--context-shown) " root"))
      ;; `exit': run0 closes its context, then the outer prompt closes the command
      ;; and re-opens its shell.
      (cooked-tests--context "end=33333333333333333333333333333333"
                             "end=22222222222222222222222222222222;exit=success"
                             shell)
      (should (equal cooked-osc-context--stack
                     '(("11111111111111111111111111111111" . shell))))
      (should (equal (cooked-tests--context-shown) "")))))

(ert-deftest cooked-osc-context-a-killed-run0-is-forgotten-at-the-next-prompt ()
  "No `end=' at all -- run0 was SIGKILLed -- and the outer shell's update heals it."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--context "start=S;type=shell" "start=C;type=command" "start=R;type=elevate")
    (should (equal (cooked-tests--context-shown) " root"))
    (cooked-tests--context "end=C;exit=failure;status=137;signal=SIGKILL" "start=S;type=shell")
    (should (equal cooked-osc-context--stack '(("S" . shell))))
    (should (equal (cooked-tests--context-shown) ""))))

(ert-deftest cooked-osc-context-stack-rules ()
  (with-temp-buffer
    (cooked-mode)
    ;; An `end=' for an id that is not open changes nothing.
    (cooked-tests--context "start=A;type=container" "end=nope")
    (should (equal cooked-osc-context--stack '(("A" . container))))
    ;; Innermost interesting wins, and an update replaces the type outright.
    (cooked-tests--context "start=B;type=vm")
    (should (equal (cooked-tests--context-shown) " vm"))
    (cooked-tests--context "start=A;type=remote")
    (should (equal cooked-osc-context--stack '(("A" . remote))))
    (should (equal (cooked-tests--context-shown) " remote"))
    ;; An update with no type forgets the old one: the spec resets every field.
    (cooked-tests--context "start=A;user=simon")
    (should (equal cooked-osc-context--stack '(("A"))))
    (should (equal (cooked-tests--context-shown) ""))
    ;; Fields in any order, `type=' last or first.
    (cooked-tests--context "start=D;type=elevate;user=root" "start=E;comm=x;type=vm")
    (should (equal (mapcar #'cdr cooked-osc-context--stack) '(vm elevate nil)))
    ;; Ending an outer context ends what is inside it.
    (cooked-tests--context "end=D")
    (should (equal cooked-osc-context--stack '(("A"))))))

(ert-deftest cooked-osc-context-repaints-only-when-the-label-changes ()
  "The stock snippet's `shell' and `command' contexts change no label, so they
ask the mode line for nothing; opening and closing `elevate' does."
  (with-temp-buffer
    (cooked-mode)
    (let ((repaints 0))
      (cl-letf (((symbol-function 'force-mode-line-update)
                 (lambda (&rest _) (cl-incf repaints))))
        (dotimes (_ 3)
          (cooked-tests--context "start=S;type=shell" "start=C;type=command"
                                 "end=C;exit=success"))
        (should (= repaints 0))
        (cooked-tests--context "start=R;type=elevate")
        (should (= repaints 1))
        (cooked-tests--context "start=I;type=shell" "end=I" "start=I;type=command")
        (should (= repaints 1))
        (cooked-tests--context "end=R")
        (should (= repaints 2))))))

(ert-deftest cooked-osc-context-no-child-text-reaches-the-mode-line ()
  "Every field the child chose is ignored, and a malformed head is refused."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--context
     "start=X;type=container;container=%b pwned;hostname=%]evil;user=root")
    (should (equal (cooked-tests--context-shown) " container"))
    (setq cooked-osc-context--stack nil)
    (dolist (bad (list "start=" "begin=abc;type=elevate" "START=abc;type=elevate"
                       "start=abc\tdef;type=elevate"
                       (concat "start=" (make-string 65 ?a) ";type=elevate")
                       "start=\xff;type=elevate" "type=elevate"))
      (cooked--handle-osc 3008 nil (split-string bad ";")))
    (should-not cooked-osc-context--stack)
    ;; A type outside the spec's twelve opens a context that is never shown.
    (cooked-tests--context "start=abc;type=root" "start=def;type=elevate ")
    (should (equal cooked-osc-context--stack '(("def") ("abc"))))
    (should (equal (cooked-tests--context-shown) ""))))

(ert-deftest cooked-osc-context-depth-keeps-the-outermost ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--context "start=root;type=elevate")
    (dotimes (i 100)
      (cooked-tests--context (format "start=sub%d;type=subcontext" i)))
    (should (= (length cooked-osc-context--stack) cooked-osc-context--depth))
    (should (equal (car (last cooked-osc-context--stack)) '("root" . elevate)))
    (should (equal (cooked-tests--context-shown) " root"))))

(ert-deftest cooked-osc-context-elevate-cannot-be-hidden ()
  "The three probes of a child hiding `root'.
An inner context with a label of its own does not replace it, and a stack
filled to the limit first does not keep it out.  An update that leaves out
`type=' does drop it: the spec resets every field an update does not resend."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--context "start=a;type=elevate" "start=b;type=container")
    (should (equal (cooked-tests--context-shown) " root"))
    (should (eq (get-text-property 1 'face (cooked-osc-context--mode-line))
                'cooked-osc-context-elevate))
    ;; Without `elevate' in the labels, the innermost labelled one is shown.
    (let ((cooked-osc-context-labels (assq-delete-all
                                      'elevate (copy-alist cooked-osc-context-labels))))
      (should (equal (cooked-tests--context-shown) " container")))
    (setq cooked-osc-context--stack nil)
    ;; Filled with typeless junk, the stack still admits an elevate, but only one.
    (dotimes (i cooked-osc-context--depth)
      (cooked-tests--context (format "start=junk%d" i)))
    (cooked-tests--context "start=r;type=elevate")
    (should (equal (cooked-tests--context-shown) " root"))
    (should (= (length cooked-osc-context--stack) (1+ cooked-osc-context--depth)))
    (cooked-tests--context "start=r2;type=elevate" "start=v;type=vm")
    (should (= (length cooked-osc-context--stack) (1+ cooked-osc-context--depth)))
    (should-not (assoc "r2" cooked-osc-context--stack))
    ;; An update without `type=' forgets it, as the spec says.
    (cooked-tests--context "start=r;user=root")
    (should (equal (cooked-tests--context-shown) ""))))

(ert-deftest cooked-osc-context-labels-are-the-knob ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--context "start=a;type=elevate" "start=b;type=chpriv;targetuser=nobody")
    (should (equal (cooked-tests--context-shown) " root"))
    (let ((cooked-osc-context-labels (cons '(chpriv . "100% user") cooked-osc-context-labels)))
      ;; Labelled, but inside a root shell, which still says so.
      (should (equal (cooked-tests--context-shown) " root"))
      ;; Escaped once, so the mode line prints the `%' rather than reading it.
      (cooked-tests--context "end=a" "start=b;type=chpriv;targetuser=nobody")
      (should (equal (cooked-tests--context-shown) " 100% user")))
    (let ((cooked-osc-context-labels nil))
      (should-not (cooked-osc-context--mode-line)))
    ;; A dead session is somewhere no longer.
    (let ((cooked--exit 0))
      (should-not (cooked-osc-context--mode-line)))))

(ert-deftest cooked-osc-context-survives-ris-from-a-real-child ()
  "End to end through the core, which passes OSC 3008 through untouched.
RIS in the middle must not clear the stack -- the spec's safety rule -- and the
`end=' after it must."
  :tags '(pty)
  (cooked-tests--with-session
      `("/bin/sh" "-c"
        ,(concat "printf '\\033]3008;start=33333333333333333333333333333333"
                 cooked-tests--context-common ";type=elevate\\033\\\\';"
                 " printf '\\033c'; sleep 1;"
                 " printf '\\033]3008;end=33333333333333333333333333333333\\033\\\\';"
                 " sleep 5"))
    (should (cooked-tests--settle
             (lambda () (equal (cooked-tests--context-shown) " root"))))
    (should (cooked-tests--settle (lambda () (null cooked-osc-context--stack))))
    (should (equal (cooked-tests--context-shown) ""))))

(ert-deftest cooked-osc-context-outlives-marks-and-not-the-child ()
  "A `run0 bash' prompts inside its `elevate', so its OSC 133 marks leave the
stack alone.  The child exiting ends every context, so a session started in the
same buffer afterwards does not begin as root."
  :tags '(pty)
  (let ((go (make-temp-name (expand-file-name "cooked-context-go" temporary-file-directory))))
    (unwind-protect
        (cooked-tests--with-session
            `("/bin/sh" "-c"
              ,(concat "printf '\\033]3008;start=44444444444444444444444444444444"
                       cooked-tests--context-common ";type=elevate\\033\\\\';"
                       " printf '\\033]133;C\\007\\033]133;D;0\\007\\033]133;A\\007$ ';"
                       (format " while [ ! -e %s ]; do sleep 0.05; done; exit 0" go)))
          (should (cooked-tests--settle
                   (lambda () (and (equal (cooked-tests--context-shown) " root")
                                   (string-match-p "\\$" (cooked-tests--text))))))
          (write-region "" nil go)
          (should (cooked-tests--settle (lambda () cooked--exit)))
          (should-not cooked-osc-context--stack))
      (ignore-errors (delete-file go)))))

(provide 'cooked-tests-osc-context)
;;; cooked-tests-osc-context.el ends here
