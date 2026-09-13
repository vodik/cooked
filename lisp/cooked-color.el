;;; cooked-color.el --- The colours a buffer draws with, as the child sees them -*- lexical-binding: t; -*-

;;; Commentary:

;; The native core has no default foreground or background at all: those are
;; whatever this buffer's faces resolve to under the user's theme.  So everything
;; a child can ask or change about them is answered here -- OSC 10, 11 and 12
;; for the defaults and the cursor, OSC 4 for the palette, the light or dark
;; scheme the core reports for mode 2031, and DECSCNM, which draws the whole
;; screen with the two defaults swapped.
;;
;; It sits on cooked-osc.el, which dispatches the OSC queries to it, and is read
;; by the drain pipeline for DECSCNM.

;;; Code:

(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-face)
(require 'cooked-osc)

(cooked--declare-core)

(provide 'cooked-color)
;;; cooked-color.el ends here
