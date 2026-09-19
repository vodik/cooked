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

use super::{CellMetrics, Mouse, MouseFormat, Term};

/// What X10 adds to every field so that no field can be a control byte. Coordinates are
/// 1-based on top of it, which is where the 33s below come from.
const X10_BIAS: u32 = 32;

/// The button number a release reports in X10, which has no field to name the button
/// being let go of, and what a 1003 child is told when the pointer moves with nothing
/// down.
const X10_NO_BUTTON: u32 = 3;

impl Term {
    /// The report for BUTTON at ROW/COL, spelled as this child asked and measured against
    /// the cell size it was last told about, or `None` if it does not want the mouse.
    ///
    /// The two readings are taken together, which is the point of asking here at all: the
    /// format and the cell size both belong to the child, and a report built from one of
    /// them as it was at the last drain and the other as it is now names a place neither
    /// end agrees on. `None` is the same answer given for the same reason -- the child
    /// turned tracking off after Emacs decided a click was its to hear, and the click
    /// belongs to nobody.
    pub(crate) fn mouse_report(
        &self,
        button: u32,
        row: u64,
        col: u64,
        pressed: bool,
        offset: Option<(i64, i64)>,
    ) -> Option<Vec<u8>> {
        let mouse = self.mouse();
        mouse
            .enabled()
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
        button: u32,
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
fn sgr(button: u32, x: u64, y: u64, pressed: bool) -> Vec<u8> {
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
fn x10(button: u32, row: u64, col: u64, pressed: bool) -> Vec<u8> {
    let field = |n: u64| {
        char::from_u32(u32::try_from(n).unwrap_or(u32::MAX)).unwrap_or(char::REPLACEMENT_CHARACTER)
    };
    let named = if pressed { button } else { X10_NO_BUTTON };
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
    use crate::emu::term::MouseTracking;

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
        assert_eq!(m.report(0, 4, 9, true, None, None), b"\x1b[<0;10;5M");
        assert_eq!(m.report(0, 4, 9, false, None, None), b"\x1b[<0;10;5m");
        assert_eq!(m.report(64, 0, 0, true, None, None), b"\x1b[<64;1;1M");
        // A wheel notch is a press. Emacs calls a notch a click, and a report that
        // went out as `m' would reach the child and be discarded: applications throw
        // away a release of buttons 64 and 65.
        assert_eq!(m.report(64, 3, 5, true, None, None), b"\x1b[<64;6;4M");
    }

    #[test]
    fn x10_biases_by_thirty_two_and_names_no_button_on_release() {
        let m = mouse(MouseFormat::X10);
        assert_eq!(m.report(0, 0, 0, true, None, None), b"\x1b[M !!");
        assert_eq!(m.report(0, 2, 4, true, None, None), b"\x1b[M %#");
        // Every release is button 3, so the two wheel directions become one report.
        assert_eq!(m.report(0, 0, 0, false, None, None), b"\x1b[M#!!");
        // Which is worse than merely ignored for a wheel notch: a release cannot say
        // which way the wheel turned.
        assert_eq!(
            m.report(64, 3, 5, false, None, None),
            m.report(65, 3, 5, false, None, None)
        );
        assert_ne!(
            m.report(64, 3, 5, true, None, None),
            m.report(65, 3, 5, true, None, None)
        );
    }

    #[test]
    fn x10_past_the_223_column_limit_spells_the_field_in_utf8() {
        let m = mouse(MouseFormat::X10);
        // Column 94 is the last that biases to a single byte, 127.
        assert_eq!(m.report(0, 0, 94, true, None, None), b"\x1b[M \x7f!");
        // One further is U+0080, which reaches the pty as the two bytes of its UTF-8.
        assert_eq!(m.report(0, 0, 95, true, None, None), b"\x1b[M \xc2\x80!");
        // And 223, the column the form is usually said to stop at, is U+00FF.
        assert_eq!(m.report(0, 0, 222, true, None, None), b"\x1b[M \xc3\xbf!");
    }

    #[test]
    fn pixels_scale_the_reported_cell_and_add_the_offset() {
        let m = mouse(MouseFormat::SgrPixels);
        let c = cell(9, 20);
        // Row 3, column 5, four pixels right and seven down inside it.
        assert_eq!(
            m.report(0, 3, 5, true, Some((4, 7)), c),
            b"\x1b[<0;50;68M".as_slice()
        );
        assert_eq!(
            m.report(0, 3, 5, false, Some((4, 7)), c),
            b"\x1b[<0;50;68m".as_slice()
        );
        // The child divides by the size it was told, and lands back in the cell.
        assert_eq!((50 - 1) / 9, 5);
        assert_eq!((68 - 1) / 20, 3);
        // No offset is a position standing in for the pointer: the cell's corner.
        assert_eq!(
            m.report(64, 3, 5, true, None, c),
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
            m.report(0, 3, 5, true, Some((4, 25)), c),
            b"\x1b[<0;50;80M".as_slice()
        );
        // An image's ascent can put the pointer above the row's top; a wide glyph's own
        // offset is real and passes through.
        assert_eq!(
            m.report(0, 3, 5, true, Some((14, -2)), c),
            b"\x1b[<0;60;61M".as_slice()
        );
    }

    #[test]
    fn a_frame_with_no_cell_size_reports_cells_counted_from_one() {
        let m = mouse(MouseFormat::SgrPixels);
        assert_eq!(
            m.report(0, 3, 5, true, Some((4, 7)), None),
            b"\x1b[<0;6;4M".as_slice()
        );
    }

    #[test]
    fn a_one_pixel_cell_leaves_no_room_for_an_offset() {
        let m = mouse(MouseFormat::SgrPixels);
        assert_eq!(
            m.report(0, 3, 5, true, Some((7, 7)), cell(1, 1)),
            b"\x1b[<0;13;4M".as_slice(),
            "dy clamps to zero, the only pixel the row has; dx has no clamp"
        );
    }
}
