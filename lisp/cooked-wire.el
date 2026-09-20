;;; cooked-wire.el --- Constants the native core owns  -*- lexical-binding: t; -*-

;;; Commentary:

;; Generated, do not edit.  `make wire' rewrites this file from the `wire_layout'
;; tables in src/wire.rs, src/emu/cell.rs, src/emu/glyph.rs and src/session.rs and
;; from `NamedKey' in src/emu/term/keypress.rs, and `make lint' fails while what is
;; checked in differs from what those tables say.
;;
;; Checked in rather than built, because the package is installed by straight or ELPA
;; and may run against a downloaded prebuilt core: byte-compilation has to work on a
;; machine with no cargo and no src/ beside it.  And wanted at compile time, because
;; `cooked--do-style-spans' expands these numbers into literals and
;; `cooked--build-passthrough-map' binds every key name before the module is loaded --
;; neither can wait for `cooked--wire-layout' to be callable.
;;
;; So the core is still the one owner, and the check moves to load time: the loaded
;; core reports the same table through `cooked--wire-layout', and
;; `cooked--check-wire-drift' says so when a stale .so disagrees with this file.

;;; Code:

(defconst cooked--attr-bold 1
  "SGR 1, bold.")

(defconst cooked--attr-faint 2
  "SGR 2, faint.")

(defconst cooked--attr-italic 4
  "SGR 3, italic.")

(defconst cooked--attr-underline 8
  "SGR 4, underlined at all, whatever the style.")

(defconst cooked--attr-blink 16
  "SGR 5, blinking.")

(defconst cooked--attr-reverse 32
  "SGR 7, foreground and background swapped.")

(defconst cooked--attr-conceal 64
  "SGR 8, drawn in the background colour.")

(defconst cooked--attr-strike 128
  "SGR 9, struck through.")

(defconst cooked--attr-underline-shift 8
  "Bit position of the underline-style field.  See `Attrs' in src/emu/cell.rs.")

(defconst cooked--attr-underline-style 1792
  "Mask of the underline-style field, kitty's `SGR 4:1' to `SGR 4:5'.")

(defconst cooked--attr-overline 2048
  "SGR 53, above the underline-style field.  See `Attrs' in src/emu/cell.rs.")

(defconst cooked--glyph-record 4
  "Bytes in one packed glyph-run record.  See `Deco::packed' in src/emu/cell.rs.

The stride a reader steps by to find the next record; the fields are `u16's at
the offsets the constants below name.  The Rust side asserts the same number,
so a field added to the record on one side without widening it on both
desynchronises the two at the second record of the first affected run.")

(defconst cooked--glyph-bits 0
  "Offset of the bit pattern in a glyph record.")

(defconst cooked--glyph-count 2
  "Offset of the run length in a glyph record.")

(defconst cooked--image-record 12
  "Bytes in one packed image-placement record.

See `Deco::packed' in src/emu/cell.rs.  One record per character, unlike a
glyph run's one record per shape, because a placement is not one decision
repeated: every cell carries its own place in the picture.  The fields are a
`u32' then four `u16's at the offsets the constants below name.")

(defconst cooked--image-id 0
  "Offset of the image id in an image record.")

(defconst cooked--image-row 4
  "Offset of the cell row in an image record.")

(defconst cooked--image-col 6
  "Offset of the cell column in an image record.")

(defconst cooked--image-cols 8
  "Offset of the column span in an image record.")

(defconst cooked--image-rows 10
  "Offset of the row span in an image record.")

(defconst cooked--box-kind-block 32768
  "Set in a descriptor that names a block element rather than a line glyph.")

(defconst cooked--box-arc 256
  "Set in a rounded corner (U+256D-U+2570).")

(defconst cooked--box-diag-forward 512
  "U+2571, a straight line from the bottom-left corner to the top-right.")

(defconst cooked--box-diag-backward 1024
  "U+2572, a straight line from the top-left corner to the bottom-right.")

(defconst cooked--box-dash-shift 11
  "Bit position of the dash code in a line descriptor.")

(defconst cooked--box-dash-mask 6144
  "Mask of the dash code in a line descriptor.

The code is 0 solid, 1 double, 2 triple, 3 quadruple; the count itself does
not fit two bits, so `cooked--box-dash-counts' decodes it.")

(defconst cooked--box-weight-none 0
  "Edge weight of a side the glyph does not draw.

Light has no constant of its own: it is the weight every other one is stated
relative to, and nothing on either side of the wire spells 1 by name.")

(defconst cooked--box-weight-heavy 2
  "A heavy edge.")

(defconst cooked--box-weight-double 3
  "A double edge.")

(defconst cooked--box-direction-up 0
  "A block filled from the top edge downwards.")

(defconst cooked--box-direction-down 1
  "A block filled from the bottom edge upwards.")

(defconst cooked--box-direction-left 2
  "A block filled from the left edge rightwards.")

(defconst cooked--box-direction-right 3
  "A block filled from the right edge leftwards.")

(defconst cooked--box-direction-full 4
  "A block covering the whole cell (U+2588).")

(defconst cooked--box-direction-shade 5
  "One of the three shade densities (U+2591-U+2593), a dither rather than a fill.")

(defconst cooked--box-direction-quadrant 6
  "One of the 2x2 quadrant glyphs (U+2596-U+259F), whose fill is a 4-bit mask.")

(defconst cooked--style-record 16
  "Bytes in one packed style span.  See `Block::push_style' in src/wire.rs.

The stride *is* the format: a reader finds the next span by adding this and
never by decoding a length.  The Rust side asserts the same number, so a field
added to the record on one side without widening it on both desynchronises the
two at the second span of the first styled row, where every later span reads
its neighbour's bytes and the buffer comes out miscoloured with nothing to
point at.

The fields are `u32's at the offsets the constants below name: START and END
as character offsets, then the ids of the span's rendition and link.  They are
available at compile time so that `cooked--do-style-spans' adds literals rather
than look up variables on the render path.")

(defconst cooked--style-start 0
  "Offset of START in a style record.")

(defconst cooked--style-end 4
  "Offset of END in a style record.")

(defconst cooked--style-id 8
  "Offset of the rendition id in a style record.")

(defconst cooked--style-link 12
  "Offset of the link id in a style record, 0 for none.")

(defconst cooked--min-redisplay-interval-ms 8
  "Redisplay floor the core falls back to, in milliseconds.

What a session is paced by when `cooked--spawn' is given no interval; the
standard value of `cooked-min-redisplay-interval' is this in seconds.")

(defconst cooked--backlog-limit 8000
  "Items the core lets pile up before it stops draining the pty.

The standard value of `cooked-backlog-limit'; see that variable for what
raising it buys and costs.")

(defconst cooked--wire-constants
  '((attr-bold . 1)
    (attr-faint . 2)
    (attr-italic . 4)
    (attr-underline . 8)
    (attr-blink . 16)
    (attr-reverse . 32)
    (attr-conceal . 64)
    (attr-strike . 128)
    (attr-underline-shift . 8)
    (attr-underline-style . 1792)
    (attr-overline . 2048)
    (glyph-record . 4)
    (glyph-bits . 0)
    (glyph-count . 2)
    (image-record . 12)
    (image-id . 0)
    (image-row . 4)
    (image-col . 6)
    (image-cols . 8)
    (image-rows . 10)
    (box-kind-block . 32768)
    (box-arc . 256)
    (box-diag-forward . 512)
    (box-diag-backward . 1024)
    (box-dash-shift . 11)
    (box-dash-mask . 6144)
    (box-weight-none . 0)
    (box-weight-heavy . 2)
    (box-weight-double . 3)
    (box-direction-up . 0)
    (box-direction-down . 1)
    (box-direction-left . 2)
    (box-direction-right . 3)
    (box-direction-full . 4)
    (box-direction-shade . 5)
    (box-direction-quadrant . 6)
    (style-record . 16)
    (style-start . 0)
    (style-end . 4)
    (style-id . 8)
    (style-link . 12)
    (min-redisplay-interval-ms . 8)
    (backlog-limit . 8000))
  "Every constant above, by the name the core gives it.

The same alist `cooked--wire-layout' returns from a loaded core, which is what
makes the comparison in `cooked--check-wire-drift' possible without naming
forty-odd constants a third time.  A name here is the constant above with its
`cooked--' prefix removed.")

(defconst cooked--key-names
  '(up down right left home end f1 f2 f3 f4 prior next insert deletechar f5 f6
    f7 f8 f9 f10 f11 f12 return tab escape backspace backtab begin kp-0 kp-1
    kp-2 kp-3 kp-4 kp-5 kp-6 kp-7 kp-8 kp-9 kp-decimal kp-add kp-subtract
    kp-multiply kp-divide kp-separator kp-enter kp-home kp-up kp-prior kp-left
    kp-begin kp-right kp-end kp-down kp-next kp-insert kp-delete f13 f14 f15
    f16 f17 f18 f19 f20 f21 f22 f23 f24 menu pause print)
  "Every non-character key cooked speaks for, by the symbol Emacs names it with.

The spelling of each is the core's, in `NamedKey' in src/emu/term/keypress.rs,
and this is that table in that order -- the order matters, because
`cooked--build-passthrough-map' binds them in it.  It is written out here
rather than read from `cooked--key-table' because the keymap is built before
the module is loaded.")

(defconst cooked--kitty-only-keys
  '(pause print)
  "Keys with no spelling outside the kitty keyboard protocol.

Pause and Print Screen send nothing in xterm and have no capability in terminfo,
and inventing a sequence for them would put bytes in a program's input that it
never agreed to read.  The protocol gives each a code point of its own, so
`cooked--build-passthrough-map' binds them only while it is negotiated; see
`cooked--kitty-only'.")

(provide 'cooked-wire)
;;; cooked-wire.el ends here
