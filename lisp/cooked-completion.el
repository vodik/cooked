;;; cooked-completion.el --- completion for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; TAB at a cooked prompt is `completion-at-point', so corfu, cape, consult and
;; friends work here exactly as they do anywhere else.  What they are offered comes
;; from one of two places.
;;
;; In Emacs: programs on PATH for the first word, file names after it.  Honest, and
;; entirely ignorant of what you are actually completing.
;;
;; From the shell: zsh's own completion system, run in the very shell you are typing
;; at, so `git checkout <TAB>' offers branches, `ssh <TAB>' offers hosts and `kill
;; <TAB>' offers processes -- with the descriptions compsys writes for them.  The line
;; being edited lives in Emacs and ZLE's buffer is empty, so this cannot work by
;; forwarding TAB; the request carries the line with it.  See `shell-integration/
;; cooked.zsh' for the other half, and `cooked--shell-completions' for the exchange.
;;
;; The shell is asked first and Emacs answers when it cannot -- a shell without the
;; integration, a slow completer, bash -- which is `cooked-completion-backend'.

;;; Code:

(require 'cooked)
(require 'cl-lib)
(require 'seq)

(declare-function cooked--send "cooked-core")

(defgroup cooked-completion nil
  "Completing at a cooked prompt."
  :group 'cooked)

(defcustom cooked-completion-backend 'shell
  "Where candidates come from at a cooked prompt.

`shell' asks the child's own completion system and falls back to Emacs
when it has nothing to say -- no integration, no answer in time, no
candidates.  `native' never asks, and completes programs and file names
in Emacs.  `both' offers the shell's candidates and appends Emacs' own,
for a `cape' or `corfu' setup that would rather see everything."
  :type '(choice (const :tag "Shell, falling back to Emacs" shell)
                 (const :tag "Emacs only" native)
                 (const :tag "Shell, then Emacs as well" both))
  :group 'cooked-completion)

(defcustom cooked-completion-timeout 0.4
  "Seconds to wait for the shell to answer a completion request.

Emacs is blocked for this long at worst, so it is a latency budget rather
than a generous allowance: a completer slower than this (a remote `ssh'
host list, `git' against a cold repository) falls back to completing in
Emacs.  Note that drains are paced by `cooked-min-redisplay-interval',
which the reply has to wait for."
  :type 'number
  :group 'cooked-completion)

;;;; The native table

(defvar cooked--executables nil "Cached PATH lookup, see `cooked--executable-table'.")

(defun cooked--executable-table ()
  "Names of programs on PATH, cached for the session."
  (or cooked--executables
      (setq cooked--executables
            (delete-dups
             (mapcan (lambda (dir)
                       (when (file-accessible-directory-p dir)
                         (ignore-errors (directory-files dir nil "\\`[^.]" t))))
                     exec-path)))))

(defun cooked-flush-executables ()
  "Forget the cached list of programs on PATH."
  (interactive)
  (setq cooked--executables nil))

(defun cooked--completion-bounds ()
  "Bounds of the word before point, clamped to the pending input."
  (let ((limit (cooked--input-start-position)))
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t" limit)
        (cons (point) end)))))

(defun cooked--native-completion ()
  "Completion in Emacs: a program name first, file names after it."
  (pcase-let* ((`(,start . ,end) (cooked--completion-bounds))
               ;; The first word of the line is the command; everything after it
               ;; is an argument, and arguments are file names far more often
               ;; than not.
               (first-word (eql start (cooked--input-start-position))))
    (list start end
          (if first-word
              (completion-table-in-turn (cooked--executable-table)
                                        #'completion-file-name-table)
            #'completion-file-name-table)
          :exclusive 'no
          :annotation-function (lambda (_) (when first-word " program")))))

;;;; Asking the shell
;;
;; The exchange, in full:
;;
;;   shell  ESC ] 51 ; C H ; VERSION ; NONCE ST      at every new ZLE line
;;   Emacs  ESC [ > 99 u NONCE ; SERIAL ; POINT ; LINE LF
;;   shell  ESC ] 51 ; C R ; SERIAL ; PREFIX ; SUFFIX ; TRUNCATED ; BASE64 ST
;;
;; The announcement is what makes this safe to send at all.  Without a widget bound
;; to that key the request would be read as ordinary input -- by bash, by a nested
;; `zsh -f', by whatever is on the far end of an ssh -- so nothing is sent until the
;; shell has said, for this prompt, that it is listening.  The nonce goes back with
;; the request so the shell can refuse one built against a line it has already left.
;;
;; LINE is percent-encoded, every byte of it: selective encoding would let a literal
;; hex digit follow an escape and be swallowed by it.  The reply is base64 because a
;; description is arbitrary text and one control byte in it would end the sequence
;; carrying it.

(defvar-local cooked--completion-nonce nil
  "The current prompt's completion nonce, or nil if the shell has not offered one.")

(defvar-local cooked--completion-serial 0
  "Counter distinguishing completion requests, so a late reply can be dropped.")

(defvar-local cooked--completion-reply nil
  "Reply to the outstanding request: (SERIAL PREFIX SUFFIX TRUNCATED . RECORDS).")

(defun cooked--completion-forget-nonce ()
  "Forget the current prompt's nonce, called when the shell leaves that prompt."
  (setq cooked--completion-nonce nil))

(defun cooked--completion-encode (string)
  "Percent-encode every byte of STRING."
  (mapconcat (lambda (byte) (format "%%%02X" byte))
             (string-to-unibyte (encode-coding-string string 'utf-8))
             ""))

(defun cooked--completion-candidates (blob)
  "Parse BLOB, the decoded reply body, into (MATCH DESCRIPTION GROUP) records."
  (mapcar (lambda (record)
            (let ((fields (split-string record "\x1f")))
              (list (or (nth 0 fields) "")
                    (or (nth 1 fields) "")
                    (or (nth 2 fields) ""))))
          (seq-remove #'string-empty-p (split-string blob "\x1e"))))

(defun cooked--completion-handle (payload)
  "Handle PAYLOAD, an OSC 51;C message from the shell, minus its leading C.

Two messages arrive here: `H' announces that this prompt can complete, and `R'
answers a request.  Both are inert -- a nonce and a list of strings -- which is
why this needs none of the `cooked-osc-eval' opt-in."
  (pcase (and (not (string-empty-p payload)) (aref payload 0))
    (?H (pcase (split-string (substring payload 1) ";")
          ;; Version first, so a newer shell snippet paired with an older Emacs
          ;; declines rather than misreading the protocol.
          (`("" "2" ,nonce . ,_) (setq cooked--completion-nonce nonce))
          (_ (setq cooked--completion-nonce nil))))
    (?R (pcase (split-string (substring payload 1) ";")
          (`("" ,serial ,prefix ,suffix ,truncated ,blob . ,_)
           ;; The blob is bytes the child chose; a truncated or corrupt one is a
           ;; failed completion, not a broken redisplay.
           (when-let* ((decoded (ignore-errors
                                  (decode-coding-string (base64-decode-string blob)
                                                        'utf-8))))
             (setq cooked--completion-reply
                   `(,(string-to-number serial)
                     ,(string-to-number prefix)
                     ,(string-to-number suffix)
                     ,(equal truncated "1")
                     . ,(cooked--completion-candidates decoded)))))))))

(defun cooked--shell-completions (line point)
  "Ask the child to complete LINE with the cursor at POINT, a character offset.

Returns (PREFIX SUFFIX TRUNCATED . RECORDS), or nil if the shell cannot
or does not answer.  Blocks for at most `cooked-completion-timeout': the
reply arrives through the wake pipe like every other byte the child
writes, so pumping that process is what lets it in."
  (when (and cooked--completion-nonce (cooked--live-session))
    (let ((serial (cl-incf cooked--completion-serial)))
      (setq cooked--completion-reply nil)
      (cooked--send-if-live
       (format "\e[>99u%s;%d;%d;%s\n"
               cooked--completion-nonce serial point
               (cooked--completion-encode line)))
      (let ((deadline (+ (float-time) cooked-completion-timeout)))
        ;; `with-local-quit' rather than nothing: this is the one place cooked
        ;; blocks, and C-g has to get the user out of a shell that stopped talking.
        (with-local-quit
          (while (and (not (eq (car-safe cooked--completion-reply) serial))
                      (< (float-time) deadline))
            (accept-process-output cooked--wake (- deadline (float-time)))))
        ;; A reply for an older request is not an answer to this one; drop it rather
        ;; than complete against a line the user has already moved on from.
        (when (eq (car-safe cooked--completion-reply) serial)
          (cdr cooked--completion-reply))))))

;;;; The CAPF

(defun cooked--completion-annotation (display match)
  "The part of DISPLAY that is not MATCH, or nil when it says nothing new.

compsys formats a display string as the candidate padded out to a column, then
its description: \"checkout   -- switch branches\".  Corfu shows the candidate
itself, so only the tail is worth repeating."
  (let ((tail (if (string-prefix-p match display)
                  (substring display (length match))
                display)))
    (setq tail (string-trim tail))
    (setq tail (if (string-prefix-p "--" tail) (string-trim (substring tail 2)) tail))
    (unless (string-empty-p tail) (concat " " tail))))

(defun cooked--completion-group (group)
  "GROUP as a heading, or nil if it says nothing worth showing.

The explanation compsys hands over is the one it would have printed, so it
arrives dressed in whatever the user's `format' style asked for: prompt escapes
for colour and bold, and often a marker like \">>\" in front.  None of that
survives out of a terminal listing, and corfu is going to draw the heading
itself."
  (unless (or (null group) (equal group "-default-"))
    (let ((text group))
      ;; %F{cyan} and %K{...} first: their braces would otherwise be left behind.
      (setq text (replace-regexp-in-string "%[FKfk]{[^}]*}" "" text))
      (setq text (replace-regexp-in-string "%[BbUuSsFfKk]" "" text))
      (setq text (string-trim text))
      (setq text (string-trim (replace-regexp-in-string "\\`[-=>*#]+" "" text)))
      (unless (string-empty-p text) text))))

(defun cooked--completion-index (records extra annotations groups)
  "Index RECORDS into ANNOTATIONS and GROUPS, and return the candidates.

EXTRA is glued in front of every candidate: the part of the word that compsys
counted as already settled and answered relative to, so that everything the
table offers replaces the same span.

Duplicates are dropped keeping the first that carries a description: zsh offers
a branch under both `heads' and `commits', and the annotated one is the useful
half of that pair."
  (clrhash annotations)
  (clrhash groups)
  (let ((seen (make-hash-table :test #'equal))
        (matches nil))
    (pcase-dolist (`(,match ,display ,group) records)
      (let ((annotation (cooked--completion-annotation display match))
            (group (cooked--completion-group group))
            (candidate (concat extra match)))
        (unless (gethash candidate seen)
          (puthash candidate t seen)
          (push candidate matches))
        (when (and annotation (null (gethash candidate annotations)))
          (puthash candidate annotation annotations)
          (puthash candidate group groups))))
    (nreverse matches)))

(defun cooked--shell-completion-table (records)
  "A completion table over RECORDS, with their descriptions and groups."
  (let ((annotations (make-hash-table :test #'equal))
        (groups (make-hash-table :test #'equal)))
    (list (cooked--completion-index records "" annotations groups)
          (lambda (candidate) (gethash candidate annotations))
          (lambda (candidate transform)
            (if transform candidate (gethash candidate groups))))))

(defun cooked--completion-settled-p (word cached-word cached-matches)
  "Whether CACHED-MATCHES can answer for WORD without asking the shell again.

Only when the cached answer was complete -- the shell did not stop at its cap --
the word has only grown, and something in the list still matches it.  Each of
those is doing work:

The cap is why `pacman' was missing from a list that included `pacman-key': the
answer was cut off before it, and no filtering recovers a candidate that was
never sent.  Growth matters because a word that shrank is a different question.
And a list that no longer matches usually means the completion changed kind
rather than narrowed -- typing `-' after `git checkout ' turns branches into
flags -- which filtering cannot produce either."
  (and cached-word
       (string-prefix-p cached-word word)
       (seq-some (lambda (candidate) (string-prefix-p word candidate)) cached-matches)))

(defun cooked--completion-dynamic (head tail annotations groups seed)
  "A table that asks the shell again as the word typed into it grows.

HEAD and TAIL are the pending input on either side of the word being completed,
so the shell is always asked about a whole command line rather than a fragment.
ANNOTATIONS and GROUPS are refilled by each query.  SEED is (WORD TRUNCATED .
RECORDS), the answer already in hand for the word as it stands, so opening the
popup does not cost a second round trip.

Which keystrokes are worth a round trip is `cooked--completion-settled-p'.  The
rest are filtered in Emacs, which is instant and exact -- and the difference is
not academic: a completer that takes 140ms is one that stutters if it is asked
on every letter."
  (let ((buffer (current-buffer))
        (word (car seed))
        (truncated (cadr seed))
        (matches (cooked--completion-index (cddr seed) "" annotations groups)))
    (completion-table-dynamic
     (lambda (input)
       (with-current-buffer buffer
         (unless (or (equal word input)
                     (and (not truncated)
                          (cooked--completion-settled-p input word matches)))
           (pcase (cooked--shell-completions (concat head input tail)
                                             (+ (length head) (length input)))
             (`(,prefix ,_suffix ,cut . ,(and records (guard records)))
              ;; What the shell answered relative to may be less than the whole
              ;; word: typing `=' in `--date=' moves compsys past it, and the
              ;; candidates that come back are the values alone.  Gluing the rest
              ;; of the word back on keeps every candidate replacing the span the
              ;; completion was started with.
              (let ((extra (substring input 0 (max 0 (- (length input) prefix)))))
                (setq word input
                      truncated cut
                      matches (cooked--completion-index records extra
                                                        annotations groups))))
             ;; A query that fails mid-word -- the shell busy, a completer past the
             ;; timeout -- keeps the last answer rather than emptying the popup
             ;; under the user.
             (_ nil)))
         matches)))))

(defun cooked-completion-at-point ()
  "Complete the pending input.

From the shell where it can answer, and from Emacs where it cannot."
  (when-let* (((cooked--input-state-p))
              (region (cooked--input-region))
              ((>= (point) (car region))))
    (let* ((start (car region))
           (end (max start (cdr region)))
           (line (buffer-substring-no-properties start end))
           (offset (- (point) start))
           (reply (unless (eq cooked-completion-backend 'native)
                    (cooked--shell-completions line offset))))
      (pcase reply
        (`(,prefix ,_suffix ,truncated . ,(and records (guard records)))
         (let* ((word-start (max start (- (point) prefix)))
                (annotations (make-hash-table :test #'equal))
                (groups (make-hash-table :test #'equal))
                (table (cooked--completion-dynamic
                        (buffer-substring-no-properties start word-start)
                        (buffer-substring-no-properties (point) end)
                        annotations groups
                        `(,(buffer-substring-no-properties word-start (point))
                          ,truncated . ,records))))
           (list word-start (point)
                 (if (eq cooked-completion-backend 'both)
                     (completion-table-in-turn table
                                               (cooked--executable-table)
                                               #'completion-file-name-table)
                   table)
                 :exclusive 'no
                 :annotation-function (lambda (candidate) (gethash candidate annotations))
                 :group-function (lambda (candidate transform)
                                   (if transform candidate (gethash candidate groups))))))
        (_ (cooked--native-completion))))))

(provide 'cooked-completion)
;;; cooked-completion.el ends here
