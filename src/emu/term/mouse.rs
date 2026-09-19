//! Spelling a mouse report the way the child asked for it.
//!
//! The decision of *whether* to report -- which cell the pointer is over, whether a drag
//! is being followed, whether the region should survive it -- is Lisp's, because that is
//! where the Emacs event is. What lives here is the spelling, because that depends on
//! modes the child can change at any moment and on the cell size this terminal last told
//! it about. Lisp used to hold a copy of both, refreshed only by a drain, so a click that
//! landed between the child turning 1006 on and Emacs next draining was encoded against
//! the state before the change and read by the child as something else entirely. Sending
//! the intent and spelling it here closes that window: the modes are read and the bytes
//! built under the one lock, from the values the child itself set.

use super::{CellMetrics, Mouse, MouseFormat, MouseTracking, Term};

/// What X10 adds to every field so that no field can be a control byte. Coordinates are
/// 1-based on top of it, which is where the 33s below come from.
const X10_BIAS: u32 = 32;

/// One xterm button byte, once it has been read as one.
///
/// The byte is not a button number with flags beside it; the flags are *in* it, and
/// xterm's own tables are written that way. The low two bits name the button -- 0, 1 and
/// 2 for the three a mouse has, and 3 for "none", which is what a release reports in X10
/// and what a 1003 child is told when the pointer moves with nothing down. Above them sit
/// `4` shift, `8` meta and `16` control; `32` says the report is motion rather than a
/// press; `64` moves the low bits into the wheel's four notches, 64 to 67; and `128` does
/// the same for buttons 8 to 11.
///
/// So a whole byte is exactly the room the encoding has, and a byte is what this accepts.
/// Lisp sends a good deal less than that -- `cooked--mouse-buttons` names 0 to 2 and 64 to
/// 67, and `cooked--report-motion` adds `cooked--mouse-motion-bit` to one of those or to
/// `cooked--mouse-no-button' -- but the bound worth stating is the encoding's rather than
/// the caller's, since both wire forms carry the byte and neither carries more: X10 biases
/// it by 32 into a single character, and SGR prints it as a number the child reads back
/// as these same bits. A larger number is a caller that has confused a button with
/// something else, and is refused here rather than spelled into a report that names a
/// button nobody pressed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Button(u8);

/// What a button byte says the pointer did, which is what decides whether the tracking
/// mode in force has anything to say about it.
///
/// Read off the byte rather than passed alongside it: the motion bit and the wheel bit are
/// part of the number Lisp computed, so this is a reading of the report rather than a
/// second opinion about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Gesture {
    /// A button going down or coming up. Every tracking mode reports these; it is what
    /// asking for the mouse at all means.
    Press,
    /// A wheel notch, which arrives as a press of one of buttons 64 to 67 and is reported
    /// under every mode for the same reason.
    Wheel,
    /// The pointer moving with a button held: a drag, which 1002 and 1003 report and 1000
    /// does not.
    Drag,
    /// The pointer moving with nothing held, which only 1003 asks for.
    Hover,
}

impl Button {
    /// The button number standing for "no button", which is both what X10 substitutes for
    /// a release and what motion with nothing held reports.
    const NONE: u8 = 3;
    /// The bit saying the report is motion rather than a press or a release.
    const MOTION: u8 = 32;
    /// The bit moving the low two bits into the wheel's notches, 64 to 67.
    const WHEEL: u8 = 64;

    /// RAW as a button byte, or `None` for a number that cannot be one.
    ///
    /// Parsed once, at the FFI boundary, so that everything below holds a number the
    /// encoding can express and nothing re-asks; see [`Button`] for the bound and why it
    /// is the encoding's rather than Lisp's.
    pub(crate) fn parse(raw: i64) -> Option<Self> {
        u8::try_from(raw).ok().map(Self)
    }

    /// The number an SGR report prints, which is the byte itself: 1006 puts the button
    /// byte on the wire as decimal digits, modifiers, motion bit and all.
    fn get(self) -> u32 {
        u32::from(self.0)
    }

    /// The number an X10 report names, which is the byte for a press and
    /// [`Button::NONE`] for a release.
    ///
    /// The original form has no field for the button being let go of, so every release is
    /// button 3 -- which is why a wheel notch released cannot say which way the wheel
    /// turned, and why `Mouse` prefers 1006 wherever the child has offered it.
    fn x10(self, pressed: bool) -> u32 {
        if pressed {
            self.get()
        } else {
            u32::from(Self::NONE)
        }
    }

    /// What this report says the pointer did.
    ///
    /// The wheel is looked at before the motion bit: a notch cannot be held and cannot be
    /// dragged, so a wheel number is a notch whatever else is set, and reading it as
    /// motion would let a tracking mode refuse a scroll.
    pub(crate) fn gesture(self) -> Gesture {
        if self.0 & Self::WHEEL != 0 {
            Gesture::Wheel
        } else if self.0 & Self::MOTION == 0 {
            Gesture::Press
        } else if self.0 & 0b11 == Self::NONE {
            Gesture::Hover
        } else {
            Gesture::Drag
        }
    }
}

impl Mouse {
    /// Whether the mode the child holds now reports GESTURE at all.
    ///
    /// This is the half of the stale-mirror window that `enabled` alone does not close.
    /// Lisp decides whether to follow the pointer from `cooked--mouse-state`, which is
    /// only as fresh as the last drain, so a child that narrowed 1003 to 1002 -- or 1002
    /// to 1000 -- goes on receiving motion it never asked for until Emacs next drains.
    /// A child reading raw bytes does not ignore an unasked-for report; it reads it as
    /// whatever the sequence means to it. So the question is asked here, against the
    /// mode the child itself set, and a report no mode covers is dropped rather than
    /// sent.
    fn covers(self, gesture: Gesture) -> bool {
        match (self.tracking, gesture) {
            (MouseTracking::Off, _) => false,
            (_, Gesture::Press | Gesture::Wheel) => true,
            (MouseTracking::Drag | MouseTracking::Motion, Gesture::Drag) => true,
            (MouseTracking::Motion, Gesture::Hover) => true,
            (MouseTracking::Click, Gesture::Drag | Gesture::Hover) => false,
            (MouseTracking::Drag, Gesture::Hover) => false,
        }
    }
}

impl Term {
    /// The report for BUTTON at ROW/COL, spelled as this child asked and measured against
    /// the cell size it was last told about, or `None` if it does not want the mouse.
    ///
    /// The two readings are taken together, which is the point of asking here at all: the
    /// format and the cell size both belong to the child, and a report built from one of
    /// them as it was at the last drain and the other as it is now names a place neither
    /// end agrees on. `None` is the same answer given for the same reason -- the child
    /// turned tracking off, or narrowed it past the gesture BUTTON spells, after Emacs
    /// decided a click was its to hear, and the click belongs to nobody. See
    /// [`Mouse::covers`].
    pub(crate) fn mouse_report(
        &self,
        button: Button,
        row: u64,
        col: u64,
        pressed: bool,
        offset: Option<(i64, i64)>,
    ) -> Option<Vec<u8>> {
        let mouse = self.mouse();
        mouse
            .covers(button.gesture())
            .then(|| mouse.report(button, row, col, pressed, offset, self.cell_metrics()))
    }
}

impl Mouse {
    /// The report for BUTTON at ROW/COL, pressed or released, as the child spelled it.
    ///
    /// ROW and COL are cells counted from zero, as the grid counts them; every wire form
    /// here counts from one and adds the bias itself. OFFSET is where in the cell the
    /// pointer actually is, in pixels, for the one form that has anywhere to put it --
    /// `None` for a report whose position stood in for the pointer's (a wheel notch over
    /// the fringe, a release carried off the screen), which then names the cell's
    /// top-left pixel. CELL is the size this terminal last reported to the child, which
    /// is what the child will divide by.
    ///
    /// Under DEC mode 1016 the coordinates are pixels: the cell scaled by CELL plus the
    /// offset, counted from 1 as xterm counts them, so that pixel P lies in cell
    /// `(P - 1) / WIDTH`. DY is clamped into the row because a row holding a taller
    /// fallback glyph is drawn taller than the cell, and its excess must not read as the
    /// row below. DX needs no clamp, because the caller has already moved whole cells of
    /// it into COL.
    ///
    /// With no cell size -- a terminal frame, where there are no pixels to report -- 1016
    /// degrades to cells counted from 1, a unit of one pixel per cell being the only
    /// claim that is not invented, and the offset is dropped with the measurement it was
    /// measured against. DECRQM still answers that 1016 is set, because this terminal
    /// cannot know what kind of frame its buffer is shown on; what the child does learn
    /// is that `CSI 16 t` reports no size, and a child cannot scale pixels without asking
    /// that first.
    pub(crate) fn report(
        self,
        button: Button,
        row: u64,
        col: u64,
        pressed: bool,
        offset: Option<(i64, i64)>,
        cell: Option<CellMetrics>,
    ) -> Vec<u8> {
        match self.format {
            MouseFormat::SgrPixels => {
                let (dx, dy) = cell.and(offset).unwrap_or((0, 0));
                let width = cell.map_or(1, |c| u64::from(c.width()));
                let height = cell.map_or(1, |c| u64::from(c.height()));
                let x = col.saturating_mul(width).saturating_add(dx.max(0) as u64);
                let y = row
                    .saturating_mul(height)
                    .saturating_add(dy.clamp(0, height as i64 - 1) as u64);
                sgr(button, x.saturating_add(1), y.saturating_add(1), pressed)
            }
            MouseFormat::Sgr => sgr(
                button,
                col.saturating_add(1),
                row.saturating_add(1),
                pressed,
            ),
            MouseFormat::X10 => x10(button, row, col, pressed),
        }
    }
}

/// `ESC [ < BUTTON ; X ; Y M`, or `m` for a release: DEC mode 1006.
///
/// The `<` is the whole of what tells the child it is reading an SGR report rather than
/// an X10 one, and the final byte is the whole of what tells it a button went up -- which
/// is the point of the form: X10 reports every release as button 3, so a wheel notch let
/// go of cannot say which way the wheel turned.
fn sgr(button: Button, x: u64, y: u64, pressed: bool) -> Vec<u8> {
    let button = button.get();
    format!("\x1b[<{button};{x};{y}{}", if pressed { 'M' } else { 'm' }).into_bytes()
}

/// `ESC [ M` and three biased fields: the original report, which cannot name a cell past
/// 223.
///
/// A field wider than that is written as the character it biases to, in UTF-8, which is
/// what Emacs did with it when this encoder was Lisp -- `(string (+ 33 col))` on a column
/// past 94 is a multibyte character, and the string Emacs hands the pty is its UTF-8.
/// That is xterm's mode 1005 rather than its 1000, arrived at by accident on both sides,
/// and it is kept because the alternative is a truncated byte that names a different
/// cell. Neither is right; a child that cares asks for 1006, which is why `Mouse` prefers
/// it wherever it has been offered.
fn x10(button: Button, row: u64, col: u64, pressed: bool) -> Vec<u8> {
    let field = |n: u64| {
        char::from_u32(u32::try_from(n).unwrap_or(u32::MAX)).unwrap_or(char::REPLACEMENT_CHARACTER)
    };
    let named = button.x10(pressed);
    let mut out = b"\x1b[M".to_vec();
    let mut push = |n: u64| {
        let c = field(n);
        out.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes());
    };
    push(u64::from(X10_BIAS.saturating_add(named)));
    push(col.saturating_add(u64::from(X10_BIAS) + 1));
    push(row.saturating_add(u64::from(X10_BIAS) + 1));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RAW as the button byte it is, for a test that means to write one down.
    fn b(raw: i64) -> Button {
        Button::parse(raw).expect("a button byte")
    }

    fn mouse(format: MouseFormat) -> Mouse {
        Mouse {
            tracking: MouseTracking::Click,
            format,
        }
    }

    fn cell(width: u16, height: u16) -> Option<CellMetrics> {
        CellMetrics::new(width, height)
    }

    #[test]
    fn sgr_counts_cells_from_one() {
        let m = mouse(MouseFormat::Sgr);
        assert_eq!(m.report(b(0), 4, 9, true, None, None), b"\x1b[<0;10;5M");
        assert_eq!(m.report(b(0), 4, 9, false, None, None), b"\x1b[<0;10;5m");
        assert_eq!(m.report(b(64), 0, 0, true, None, None), b"\x1b[<64;1;1M");
        // A wheel notch is a press. Emacs calls a notch a click, and a report that
        // went out as `m' would reach the child and be discarded: applications throw
        // away a release of buttons 64 and 65.
        assert_eq!(m.report(b(64), 3, 5, true, None, None), b"\x1b[<64;6;4M");
    }

    #[test]
    fn x10_biases_by_thirty_two_and_names_no_button_on_release() {
        let m = mouse(MouseFormat::X10);
        assert_eq!(m.report(b(0), 0, 0, true, None, None), b"\x1b[M !!");
        assert_eq!(m.report(b(0), 2, 4, true, None, None), b"\x1b[M %#");
        // Every release is button 3, so the two wheel directions become one report.
        assert_eq!(m.report(b(0), 0, 0, false, None, None), b"\x1b[M#!!");
        // Which is worse than merely ignored for a wheel notch: a release cannot say
        // which way the wheel turned.
        assert_eq!(
            m.report(b(64), 3, 5, false, None, None),
            m.report(b(65), 3, 5, false, None, None)
        );
        assert_ne!(
            m.report(b(64), 3, 5, true, None, None),
            m.report(b(65), 3, 5, true, None, None)
        );
    }

    #[test]
    fn x10_past_the_223_column_limit_spells_the_field_in_utf8() {
        let m = mouse(MouseFormat::X10);
        // Column 94 is the last that biases to a single byte, 127.
        assert_eq!(m.report(b(0), 0, 94, true, None, None), b"\x1b[M \x7f!");
        // One further is U+0080, which reaches the pty as the two bytes of its UTF-8.
        assert_eq!(m.report(b(0), 0, 95, true, None, None), b"\x1b[M \xc2\x80!");
        // And 223, the column the form is usually said to stop at, is U+00FF.
        assert_eq!(
            m.report(b(0), 0, 222, true, None, None),
            b"\x1b[M \xc3\xbf!"
        );
    }

    #[test]
    fn pixels_scale_the_reported_cell_and_add_the_offset() {
        let m = mouse(MouseFormat::SgrPixels);
        let c = cell(9, 20);
        // Row 3, column 5, four pixels right and seven down inside it.
        assert_eq!(
            m.report(b(0), 3, 5, true, Some((4, 7)), c),
            b"\x1b[<0;50;68M".as_slice()
        );
        assert_eq!(
            m.report(b(0), 3, 5, false, Some((4, 7)), c),
            b"\x1b[<0;50;68m".as_slice()
        );
        // The child divides by the size it was told, and lands back in the cell.
        assert_eq!((50 - 1) / 9, 5);
        assert_eq!((68 - 1) / 20, 3);
        // No offset is a position standing in for the pointer: the cell's corner.
        assert_eq!(
            m.report(b(64), 3, 5, true, None, c),
            b"\x1b[<64;46;61M".as_slice()
        );
    }

    #[test]
    fn a_glyph_taller_than_its_cell_reports_inside_the_row() {
        let m = mouse(MouseFormat::SgrPixels);
        let c = cell(9, 20);
        // Twenty-five pixels down a twenty-pixel cell is the last pixel of this row,
        // not the first of the next.
        assert_eq!(
            m.report(b(0), 3, 5, true, Some((4, 25)), c),
            b"\x1b[<0;50;80M".as_slice()
        );
        // An image's ascent can put the pointer above the row's top; a wide glyph's own
        // offset is real and passes through.
        assert_eq!(
            m.report(b(0), 3, 5, true, Some((14, -2)), c),
            b"\x1b[<0;60;61M".as_slice()
        );
    }

    #[test]
    fn a_frame_with_no_cell_size_reports_cells_counted_from_one() {
        let m = mouse(MouseFormat::SgrPixels);
        assert_eq!(
            m.report(b(0), 3, 5, true, Some((4, 7)), None),
            b"\x1b[<0;6;4M".as_slice()
        );
    }

    #[test]
    fn a_one_pixel_cell_leaves_no_room_for_an_offset() {
        let m = mouse(MouseFormat::SgrPixels);
        assert_eq!(
            m.report(b(0), 3, 5, true, Some((7, 7)), cell(1, 1)),
            b"\x1b[<0;13;4M".as_slice(),
            "dy clamps to zero, the only pixel the row has; dx has no clamp"
        );
    }

    /// The four gestures Lisp can spell, as the button bytes it spells them with:
    /// a press of button 0, a wheel notch, `cooked--mouse-motion-bit' over the button
    /// being dragged, and the same bit over `cooked--mouse-no-button'.
    fn gestures() -> [(Button, Gesture); 4] {
        [
            (b(0), Gesture::Press),
            (b(64), Gesture::Wheel),
            (b(32), Gesture::Drag),
            (b(35), Gesture::Hover),
        ]
    }

    #[test]
    fn a_button_byte_says_which_gesture_it_is() {
        for (button, gesture) in gestures() {
            assert_eq!(button.gesture(), gesture, "{button:?}");
        }
        // Every button that can be held drags, and the three modifier bits say nothing
        // about which gesture this is.
        assert_eq!(b(33).gesture(), Gesture::Drag);
        assert_eq!(b(34).gesture(), Gesture::Drag);
        assert_eq!(b(32 + 16 + 4).gesture(), Gesture::Drag);
        assert_eq!(b(16 + 4).gesture(), Gesture::Press);
        // The wheel is read before the motion bit, so a notch cannot be refused as motion.
        assert_eq!(b(67).gesture(), Gesture::Wheel);
        assert_eq!(b(64 + 32).gesture(), Gesture::Wheel);
    }

    #[test]
    fn a_tracking_mode_covers_the_gestures_it_asked_for() {
        let covered = |tracking| {
            let mouse = Mouse {
                tracking,
                format: MouseFormat::Sgr,
            };
            gestures().map(|(button, _)| mouse.covers(button.gesture()))
        };
        // Press, wheel, drag, hover, in that order.
        assert_eq!(covered(MouseTracking::Off), [false; 4]);
        assert_eq!(
            covered(MouseTracking::Click),
            [true, true, false, false],
            "1000 hears no motion at all"
        );
        assert_eq!(
            covered(MouseTracking::Drag),
            [true, true, true, false],
            "1002 hears motion only while a button is held"
        );
        assert_eq!(covered(MouseTracking::Motion), [true; 4]);
    }

    #[test]
    fn a_number_that_cannot_be_a_button_byte_is_refused() {
        assert_eq!(Button::parse(0), Some(b(0)));
        assert_eq!(Button::parse(255), Some(b(255)));
        assert_eq!(Button::parse(256), None);
        assert_eq!(Button::parse(-1), None);
    }
}
