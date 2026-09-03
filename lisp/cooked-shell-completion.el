;;; cooked-shell-completion.el --- completing from the child's own shell -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in, and worth understanding before you do:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-shell-completion))
;;
;; With this loaded, TAB at a cooked prompt is answered by zsh's own completion
;; system, run in the very shell you are typing at:
;;
;;   git checkout <TAB>      # branches, with their tip commits
;;   ssh <TAB>               # hosts from your config and known_hosts
;;   kill <TAB>              # processes, with their command lines
;;
;; The line being edited lives in Emacs and ZLE's buffer is empty, so this cannot
;; work by forwarding TAB; the request carries the line with it.  See
;; `shell-integration/cooked.zsh' for the other half and `cooked--shell-completions'
;; for the exchange.
;;
;; The reason it is a separate file is cost rather than danger -- the candidates
;; are a list of strings that only ever reach a completion table, so unlike
;; `cooked-osc-eval' there is nothing here to be talked into.  What loading it buys
;; is paid for twice.  In Emacs, every query blocks in `accept-process-output' for
;; up to `cooked-completion-timeout' while the shell answers.  In the shell, the
;; snippet shadows the `compadd' builtin for the life of the session: inert when
;; nothing is capturing, but every completion you run in that shell then goes
;; through a shell function rather than a builtin, forever, whether or not Emacs
;; ever asks.  Leaving this unloaded is a real and reasonable answer, and it is not
;; the same as having no completion -- `cooked-completion.el' still offers programs
;; on PATH and file names, which is what most terminals give you.
;;
;; Two seams carry the layer, both of them nil-valued in the core until this file
;; is loaded, so that "not required" and "off" are the same state rather than two
;; that can disagree:
;;
;;   `cooked-shell-completion-functions'  the CAPF asks it before falling back
;;   `cooked-osc-completion-functions'    the OSC 51;C arm dispatches through it
;;
;; Both are questions the core asks, never calls the core makes into the layer,
;; and that is forced rather than stylistic: a core that pushed a notification
;; would need something to push it at, which is exactly what an unloaded layer
;; does not provide.  The nonce's lifetime went the same way -- see
;; `cooked--shell-completions'.
;;
;; The first of them is also what `cooked--shell-invocation' reads when it builds
;; the child's environment, and that is where the halves come apart: requiring this
;; file reaches Emacs immediately -- announcements start being believed, requests
;; start being sent -- but a shell that is *already running* was told at startup not
;; to install its half, and zsh offers no cheap way to install it afterwards.  The
;; `compadd' shadow, the `zle -C' widget and its three `bindkey's are established at
;; source time.  So: load this in your init file, or restart the shell after loading
;; it.  Emacs asking nothing is the whole of the difference in the meantime.

;;; Code:

(require 'cooked)
(require 'cooked-completion)
(require 'cl-lib)
(require 'seq)

(declare-function cooked--send "cooked-core")

(defcustom cooked-completion-backend 'shell
  "Where candidates come from at a cooked prompt.

Read only while `cooked-shell-completion' is loaded; without it there is
one source and nothing to choose between.

`shell' asks the child's own completion system and falls back to Emacs
when it has nothing to say -- no integration, no answer in time, no
candidates.  `native' never asks, which makes it the runtime pause for a
loaded layer: the widget stays installed in the shell and Emacs simply
stops using it, so it is the setting to flip while chasing a slow
completer rather than the way to turn the feature off.  Not asking at all
is `unload-feature' or not requiring the file.  `both' offers the shell's
candidates and appends Emacs' own, for a `cape' or `corfu' setup that
would rather see everything."
  :type '(choice (const :tag "Shell, falling back to Emacs" shell)
                 (const :tag "Emacs only, layer idle" native)
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

;;;; Asking the shell
;;
;; The exchange, in full:
;;
;;   shell  ESC ] 51 ; C H ; VERSION ; NONCE ; REPLIES ST   at every new ZLE line
;;   Emacs  ESC [ > 99 u NONCE ; SERIAL ; POINT ; LINE LF
;;   shell  ESC ] 51 ; C R ; SERIAL ; PREFIX ; SUFFIX ; TRUNCATED ; BASE64 ST
;;
;; REPLIES is 1 or 0: whether the shell can frame the third line at all, which
;; needs `base64' out there and the rest of the exchange does not.  A shell that
;; answers 0 still announces, because the announcement is also what licenses the
;; Emacs input region -- see `cooked--completion-nonce' -- and losing an editable
;; line over a missing encoder would be an unrelated punishment.
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

(defvar-local cooked--completion-serial 0
  "Counter distinguishing completion requests, so a late reply can be dropped.")

(defvar-local cooked--completion-reply nil
  "Reply to the outstanding request: (SERIAL PREFIX SUFFIX TRUNCATED . RECORDS).")

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
  "Handle PAYLOAD, an OSC 51;C reply from the shell, minus its leading C.

Only `R' arrives here.  The `H' announcement is handled in `cooked-osc.el'
without any opt-in, because the core reads it as a license to own the input
line and has to keep doing so in sessions that never load this file; see
`cooked--completion-nonce'.  What is left is the half that is genuinely this
layer's: an answer to a question only this layer asks."
  (pcase (and (not (string-empty-p payload)) (aref payload 0))
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
  (when (and cooked--completion-nonce
             ;; The shell announced but cannot frame a reply -- no `base64' out
             ;; there.  It still owns a license to the input line; it just has
             ;; nothing to say to this.
             cooked--completion-reply-capable
             ;; ZLE is still the thing reading.  The core does forget the nonce at
             ;; `command-start', which covers the shell being replaced underneath
             ;; us, but not this: policy stays `cooked' for a *command* that reads
             ;; lines canonically (`zsh' running `cat'), and a request built on
             ;; the spent nonce would be typed into that command's stdin.
             (eq cooked--semantic 'input)
             (cooked--live-session))
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

(defun cooked--completion-settled-p (word cached-word cached-matches)
  "Whether CACHED-MATCHES, collected for CACHED-WORD, still answers for WORD.

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
             ;; What the shell answered relative to may be less than the whole
             ;; word: typing `=' in `--date=' moves compsys past it, and the
             ;; candidates that come back are the values alone.  Gluing the rest
             ;; of the word back on keeps every candidate replacing the span the
             ;; completion was started with -- the one rule for both tables here,
             ;; the seed above being the case where that head is empty.
             ;;
             ;; A PREFIX *longer* than the word, on the other hand, is an answer
             ;; this span cannot express: the shell reached back past the point
             ;; the popup was opened at, and no head glued on the front can widen
             ;; a span `completion-in-region' has already been given.  Treated as
             ;; a failed query rather than clamped to "", which would hand back
             ;; candidates that match nothing and empty the popup under the user.
             (`(,prefix ,_suffix ,cut . ,(and records (guard records)))
              (when (<= prefix (length input))
                (let ((extra (substring input 0 (- (length input) prefix))))
                  (setq word input
                        truncated cut
                        matches (cooked--completion-index records extra
                                                          annotations groups)))))
             ;; A query that fails mid-word -- the shell busy, a completer past the
             ;; timeout -- keeps the last answer rather than emptying the popup
             ;; under the user.
             (_ nil)))
         matches)))))

(defun cooked--shell-completion-at-point (region)
  "Ask the shell to complete the pending input in REGION, as (START . END).

A `completion-at-point-functions' answer, or nil when the shell cannot help --
no announcement from this prompt, no reply inside `cooked-completion-timeout',
no candidates -- in which case `cooked-completion-at-point' falls back to the
Emacs table.  Bound to `cooked-shell-completion-functions' at the end of this
file, which is the whole of how the core reaches it."
  (unless (eq cooked-completion-backend 'native)
    (let* ((start (car region))
           (end (max start (cdr region)))
           (line (buffer-substring-no-properties start end))
           ;; The request's cursor, and the only description of it that survives
           ;; the round trip.  Everything below is re-derived from this rather
           ;; than read again: `cooked--shell-completions' blocks in
           ;; `accept-process-output', so the reply's own arrival drains the
           ;; child -- which lifts the pending input out of the buffer and
           ;; rebuilds it around the child's new cursor.  Positions taken before
           ;; the call therefore mean nothing after it, and a marker is no better:
           ;; the lift is a `delete-region', which collapses any marker inside it
           ;; onto the region's start.  The text comes back verbatim, so the
           ;; offset into it is exactly the thing that does survive -- the same
           ;; argument `cooked--apply''s `editing' rests on.
           (offset (- (min (point) end) start))
           (reply (cooked--shell-completions line offset)))
      ;; Re-seat on the far side of the block, and give up if there is nothing
      ;; left to re-seat into: a drain that ended the prompt -- the child ran
      ;; something, the shell exited -- takes the region with it, and there is no
      ;; line to complete any more.  Otherwise `cooked--apply' has already put
      ;; point back at the same offset and this is a no-op; it is here because
      ;; "normally a no-op" is not a property the span below can be built on, and
      ;; `completion-in-region' requires point to be inside the span it is given.
      (when-let* ((region (cooked--input-region)))
        (setq start (car region)
              end (max start (cdr region)))
        (goto-char (min (+ start offset) end))
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
          ;; Nothing the shell could say; the caller reaches the Emacs table.
          (_ nil))))))

;;;; Installing the layer
;;
;; All three at the top level, so that the file being loaded *is* the feature
;; being on.  Nothing here is undone on unload, which is the same bargain
;; `cooked-osc-eval' makes: the seams are plain variables, so a user who wants
;; the layer gone can set them back to nil themselves.

(add-hook 'cooked-shell-completion-functions #'cooked--shell-completion-at-point)
(add-hook 'cooked-osc-completion-functions #'cooked--completion-handle)

(provide 'cooked-shell-completion)
;;; cooked-shell-completion.el ends here
