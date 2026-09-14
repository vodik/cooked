;;; bench-hover-motion.el --- hover motion and typing, through the command loop, in a real frame  -*- lexical-binding: t; -*-

;; TERM.org, "Hover motion (mode 1003 with no button held)": measure before
;; deciding the default of `cooked-mouse-hover-motion'.
;;
;; The worry is not the reports -- there is one per cell crossed -- but that
;; turning the option on leaves `track-mouse' on in the terminal for as long as
;; the child wants any-motion, and every `mouse-movement' Emacs then makes is
;; read by `read-key-sequence', translated by `cooked--hover-translate' and
;; followed by whatever redisplay the command loop decides on.  So everything
;; here goes through the real command loop: the script ends in `recursive-edit',
;; and a chain of timers puts each event on `unread-command-events' for that loop
;; to read.  An earlier version sent the events through `execute-kbd-macro',
;; which reads keys without redisplaying between them, and drained the terminal
;; itself between waits, which raced the wake filter the way
;; bench-typing-latency.el once did.  Neither is left: the echo arrives only
;; through the wake filter, and every redisplay is one the command loop chose.
;;
;; Three configurations, against a child on the alternate screen that asked for
;; 1003 and SGR:
;;
;;   off     the option nil, so `track-mouse' stays nil
;;   rest    the option t and the pointer at rest: no motion events at all,
;;           which is what a pointer resting over the window produces
;;   moving  the option t and four motion events ahead of every keystroke, each
;;           into a different cell, so every one is a report the child is sent
;;
;; Each round waits out COOKED_HOVER_GAP seconds (0.03 by default) untimed, and
;; then times these:
;;
;;   motion  (`moving' only) from `cooked--hover-translate' being entered to the
;;           command loop's next wait: the translation, the report, and the
;;           redisplay the loop makes before it waits again
;;   drawn   from the typed `x' reaching `pre-command-hook' to the first wait
;;           after the wake filter has applied its echo: the command and its
;;           hooks, the child, the pacer, the apply and the paint
;;   applied the same start, to the apply
;;
;; The clocks start where the event is read rather than where the harness queued
;; it.  An event queued from a timer is read only after the redisplay Emacs makes
;; for having run a timer, which is the harness's cost and not one a window-system
;; event pays.  They stop in a timer made from inside the measured work, which
;; Emacs runs from its next wait for input, and `read_char' redisplays before it
;; waits, so the stop is on the far side of that paint.
;;
;; Beside each row: redisplays started per event, from `pre-redisplay-function',
;; and commands run per movement, from `post-command-hook', which should be none
;; now that hover is answered inside the key read.
;;
;; `rest' against `off' is the figure TERM.org asks for, and `motion' is the one
;; "Hover: every glyph crossed is a full command loop" asks for.
;;
;;     gamescope --backend headless -W 1920 -H 1080 -r 1000 --expose-wayland -- \
;;       emacs -Q -l scripts/bench-hover-motion.el
;;
;; Results go to COOKED_HOVER_OUT (default /tmp/cooked-hover.out), and
;; COOKED_HOVER_N sets the keystrokes per configuration, 1000 by default.

;; Off, deliberately: every step runs from a timer, and a debugger opened on a
;; headless frame is a run that never ends.  `hover--guard' writes errors out.
(setq debug-on-error nil)

;; Compiled, and refused on a busy machine: see bench-prelude.el.  Nothing below
;; the `cooked-bench-script-start' call runs interpreted.
(eval-and-compile
  (unless (featurep 'bench-prelude)
    (load (expand-file-name "bench-prelude"
                            (file-name-directory
                             (or load-file-name
                                 (bound-and-true-p byte-compile-current-file))))
          nil t)))
(defconst hover--out (or (getenv "COOKED_HOVER_OUT") "/tmp/cooked-hover.out"))
(cooked-bench-script-start hover--out)
(require 'cl-lib)
(require 'cooked)
(require 'cooked-mode)
(require 'cooked-bench)

(defconst hover--keystrokes
  (string-to-number (or (getenv "COOKED_HOVER_N") "1000")))

(defconst hover--gap
  (string-to-number (or (getenv "COOKED_HOVER_GAP") "0.03"))
  "Seconds between rounds, waited out untimed.
See bench-typing-latency.el for why keystrokes sent back to back measure
`cooked-min-redisplay-interval' rather than the keystroke.")

(defconst hover--movements 4 "Movements ahead of each keystroke, under `moving'.")

(defconst hover--warmup 30)

(defconst hover--timeout 2.0
  "Seconds an event may go unanswered before it counts as a timeout.")

(defvar hover--log nil)

;; Pinned for the run, for bench-typing-latency.el's reason.
(setq gc-cons-threshold (* 512 1024 1024) gc-cons-percentage 0.8)

(defun hover--say (fmt &rest args)
  (push (apply #'format fmt args) hover--log))

(defun hover--finish (code)
  "Write the log and exit with CODE."
  (with-temp-file hover--out
    (insert (mapconcat #'identity (reverse hover--log) "\n") "\n"))
  (kill-emacs code))

(defun hover--guard (fn &rest args)
  "Call FN with ARGS, turning an error into a written failure and an exit."
  (condition-case err
      (apply fn args)
    (error
     (hover--say "ERROR %S" err)
     (hover--finish 2))))

(defun hover--after (seconds fn &rest args)
  "Call FN with ARGS from a timer SECONDS from now, under `hover--guard'."
  (apply #'run-at-time seconds nil #'hover--guard fn args))

(defun hover--report (label samples extra)
  (if (null samples)
      (hover--say "%-15s no samples  %s" label extra)
    (let ((s (sort (copy-sequence samples) #'<)))
      (hover--say "%-15s n=%5d  min=%7.3f  p50=%7.3f  p99=%7.3f  max=%8.3f  %s"
                  label (length s) (car s)
                  (cooked-bench--pct s 0.50) (cooked-bench--pct s 0.99)
                  (car (last s)) extra))))

(defun hover--wait-for (predicate seconds)
  "Wait in `accept-process-output' until PREDICATE holds or SECONDS pass."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.01))
    (funcall predicate)))

;;;; Counters the command loop drives

(defvar hover--redisplays 0 "Times redisplay has started.")
(defvar hover--commands 0 "Times `post-command-hook' has run.")

(defun hover--count-redisplay (&rest _)
  (setq hover--redisplays (1+ hover--redisplays)))

(defun hover--count-command ()
  (setq hover--commands (1+ hover--commands)))

;;;; One configuration, as a chain of timers

(cl-defstruct (hover--run (:constructor hover--run-make))
  kind buffer posns done
  (round 0)
  (motion nil) (drawn nil) (applied nil)
  (motion-redisplays 0) (motion-commands 0) (key-redisplays 0)
  (timeouts 0) (reports 0)
  ;; What is awaited, as (STAGE . DATA): (motion N) until the Nth movement is
  ;; translated, (key) until `x' starts its command, and (echo TICK T0
  ;; REDISPLAYS) until the filter applies what the child sent back.
  waiting)

(defvar hover--current nil "The `hover--run' under way.")

(defun hover--measured-p (run)
  (>= (hover--run-round run) hover--warmup))

(defun hover--await (run stage)
  "Make RUN wait for STAGE, and give up on it after `hover--timeout'."
  (setf (hover--run-waiting run) stage)
  (let ((round (hover--run-round run)))
    (hover--after hover--timeout
                  (lambda ()
                    (when (and (eq (hover--run-waiting run) stage)
                               (= round (hover--run-round run)))
                      (hover--say "timeout in round %d waiting for %S" round stage)
                      (cl-incf (hover--run-timeouts run))
                      (setq unread-command-events nil)
                      (hover--next-round run))))))

(defun hover--next-round (run)
  "Close the round under way in RUN, and start the next or finish."
  (setf (hover--run-waiting run) nil)
  (cl-incf (hover--run-round run))
  (if (>= (hover--run-round run) (+ hover--warmup hover--keystrokes))
      (hover--end run)
    (hover--after hover--gap #'hover--motion run 0)))

(defun hover--motion (run n)
  "Queue the Nth movement of the round, or the keystroke after the last.

Under `off' and `rest' there is no movement, but there is still a timer where
each would have been queued, so that the key follows the same four trips round
the wait under every configuration.  It has to: the first redisplay after the
untimed gap costs some 3 ms on a pgtk frame under gamescope whatever it draws,
and without the timers that redisplay was the one after the key's command under
`off' and `rest' and an untimed one between two movements under `moving', which
made `moving' 2.4 ms faster to draw than `off' at p50."
  (cond
   ((>= n hover--movements)
    (hover--await run (list 'key))
    (setq unread-command-events (append unread-command-events (list ?x))))
   ((not (eq (hover--run-kind run) 'moving))
    (hover--after 0 #'hover--motion run (1+ n)))
   (t
    (hover--await run (list 'motion n))
    (setq unread-command-events
          (append unread-command-events
                  (list (list 'mouse-movement
                              ;; 0, 1, 0, 1 and the next round from 0 again,
                              ;; so no movement lands in the cell before it.
                              (nth (% n 2) (hover--run-posns run)))))))))

(defun hover--translated (translate prompt)
  "Around `cooked--hover-translate': time the awaited movement to the next wait."
  (let ((run hover--current))
    (if (not (and run (eq (car (hover--run-waiting run)) 'motion)))
        (funcall translate prompt)
      (let* ((n (cadr (hover--run-waiting run)))
             (t0 (float-time))
             (redisplays hover--redisplays)
             (commands hover--commands)
             (answer (funcall translate prompt)))
        (setf (hover--run-waiting run) (list 'motion-stop n))
        (unless (equal answer [])
          (hover--say "movement %d of round %d not taken out of the key: %S"
                      n (hover--run-round run) answer))
        (hover--after
         0 (lambda ()
             (when (hover--measured-p run)
               (push (* 1000 (- (float-time) t0)) (hover--run-motion run))
               (cl-incf (hover--run-motion-redisplays run)
                        (- hover--redisplays redisplays))
               (cl-incf (hover--run-motion-commands run)
                        (- hover--commands commands)))
             (hover--motion run (1+ n))))
        answer))))

(defun hover--key-read ()
  "On `pre-command-hook', first: start the awaited keystroke's clock."
  (when-let* ((run hover--current))
    (when (equal (hover--run-waiting run) '(key))
      (setf (hover--run-waiting run)
            (list 'echo
                  (buffer-chars-modified-tick (hover--run-buffer run))
                  (float-time) hover--redisplays)))))

(defun hover--applied (&rest _)
  "After a drain: if it applied the awaited echo, time the paint that follows."
  (when-let* ((run hover--current)
              (waiting (hover--run-waiting run)))
    (pcase waiting
      (`(echo ,tick ,t0 ,redisplays)
       (when (/= tick (buffer-chars-modified-tick (hover--run-buffer run)))
         (let ((t1 (float-time)))
           (setf (hover--run-waiting run) (list 'paint))
           (hover--after
            0 (lambda ()
                (when (hover--measured-p run)
                  (push (* 1000 (- (float-time) t0)) (hover--run-drawn run))
                  (push (* 1000 (- t1 t0)) (hover--run-applied run))
                  (cl-incf (hover--run-key-redisplays run)
                           (- hover--redisplays redisplays)))
                (hover--next-round run)))))))))

(defun hover--start (kind then)
  "Start a child for KIND and run its rounds; THEN is called once it has reported."
  (let ((buffer (generate-new-buffer (format "*hover %s*" kind))))
    (set-window-buffer (selected-window) buffer)
    (set-buffer buffer)
    (cooked-mode)
    ;; The child echoes the `x' it is typed and nothing else.  `cat' would send
    ;; the hover reports back too, and a report's echo arriving after the key is
    ;; read would change the buffer and pass for the key's.
    (cooked--start
     '("/bin/sh" "-c"
       "stty raw -echo; printf '\\033[?1049h\\033[?1003h\\033[?1006hREADY'; exec perl -e '$|=1; while (sysread STDIN, $b, 4096) { $b =~ tr/x//cd; syswrite STDOUT, $b if length $b }'"))
    (cooked--refresh-keymap)
    (hover--wait-for (lambda ()
                       (and (string-search "READY" (buffer-string))
                            (cooked-mouse-state-motion cooked--mouse-state)))
                     5)
    (setq cooked-mouse-hover-motion (not (eq kind 'off)))
    (cooked--update-mouse-grab)
    (redisplay t)
    (let ((run (hover--run-make
                :kind kind :buffer buffer :done then
                :posns (list (posn-at-point (point-min))
                             (posn-at-point (1+ (point-min)))))))
      (hover--say "%-8s x runs %S, track-mouse=%s (local %s), %dx%d term"
                  kind (key-binding [?x]) track-mouse
                  (local-variable-p 'track-mouse) cooked--rows cooked--cols)
      (setq hover--current run)
      ;; Round -1 closes into round 0, the first warm-up.
      (setf (hover--run-round run) -1)
      (hover--next-round run))))

(defun hover--end (run)
  "Report RUN, tear its child down, and go on to what follows."
  (let ((kind (hover--run-kind run))
        (keys (length (hover--run-drawn run)))
        (motions (length (hover--run-motion run))))
    (when (eq kind 'moving)
      (hover--report (format "%s motion" kind) (hover--run-motion run)
                     (format "%.2f redisplays and %.2f commands per movement"
                             (/ (float (hover--run-motion-redisplays run)) (max 1 motions))
                             (/ (float (hover--run-motion-commands run)) (max 1 motions)))))
    (hover--report (format "%s drawn" kind) (hover--run-drawn run)
                   (format "%.2f redisplays per key, %d timeouts, %d hover reports"
                           (/ (float (hover--run-key-redisplays run)) (max 1 keys))
                           (hover--run-timeouts run) (hover--run-reports run)))
    (hover--report (format "%s applied" kind) (hover--run-applied run) "")
    (setq hover--current nil)
    (with-current-buffer (hover--run-buffer run) (cooked--cleanup))
    (kill-buffer (hover--run-buffer run))
    (funcall (hover--run-done run))))

(defun hover--sequence (kinds)
  "Run each of KINDS in turn, then write the log and exit."
  (if kinds
      (hover--start (car kinds)
                    (lambda () (hover--after 0.2 #'hover--sequence (cdr kinds))))
    (hover--say "load after %s" (load-average t))
    (hover--finish 0)))

(when (display-graphic-p)
  (set-frame-size (selected-frame) 100 32))
(redisplay t)

(hover--say "%s" (cooked-bench-script-provenance))
(hover--say "frame %dx%d, framep=%s graphic=%s, %d keystrokes, %.3f s apart"
            (frame-width) (frame-height) (framep (selected-frame))
            (display-graphic-p) hover--keystrokes hover--gap)

(add-function :before pre-redisplay-function #'hover--count-redisplay)
(add-hook 'post-command-hook #'hover--count-command)
(add-hook 'pre-command-hook #'hover--key-read -100)
(advice-add 'cooked--hover-translate :around #'hover--translated)
(advice-add 'cooked--drain-and-apply :after #'hover--applied)
(advice-add 'cooked--send-to-child :before
            (lambda (string)
              (when (and hover--current (hover--measured-p hover--current)
                         (string-search "[<35;" string))
                (cl-incf (hover--run-reports hover--current)))))

;; A run that stalls is written out rather than left on a headless frame.
(run-at-time 900 nil (lambda ()
                       (hover--say "WATCHDOG: gave up after 900 s")
                       (hover--finish 3)))

(hover--after 0.2 #'hover--sequence '(off rest moving))
(recursive-edit)
