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

use super::{CellMetrics, Modifiers, Mouse, MouseFormat, MouseTracking, Term};

/// What X10 adds to every field so that no field can be a control byte. Coordinates are
/// 1-based on top of it, which is where the 33s below come from.
const X10_BIAS: u32 = 32;

/// A button that can be pressed, dragged and let go of again.
///
/// The three a mouse has, which xterm's low two bits number 0, 1 and 2. Buttons 8 to 11
/// live under bit 128 and are absent here because no Emacs event arrives as one:
/// `cooked--mouse-buttons' has no name to send for them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Held {
    Left,
    Middle,
    Right,
}

/// A wheel notch, which is over the instant it happens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Notch {
    Up,
    Down,
    Left,
    Right,
}

/// The button Lisp named, which is either one that can be held or a wheel notch.
///
/// What `cooked--mouse-buttons' answers for an Emacs mouse event, as a symbol: the
/// protocol's own numbering is below here and nowhere else.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Button {
    Held(Held),
    Notch(Notch),
}

impl Button {
    /// The button NAME names, or `None` for a symbol no mouse event answers.
    ///
    /// The names Lisp sends, beside the bits they spell rather than in a table of their
    /// own: `left' is the button xterm numbers 0, and `wheel-up' the notch it numbers 64.
    pub(crate) fn parse(name: &str) -> Option<Self> {
        match name {
            "left" => Some(Self::Held(Held::Left)),
            "middle" => Some(Self::Held(Held::Middle)),
            "right" => Some(Self::Held(Held::Right)),
            "wheel-up" => Some(Self::Notch(Notch::Up)),
            "wheel-down" => Some(Self::Notch(Notch::Down)),
            "wheel-left" => Some(Self::Notch(Notch::Left)),
            "wheel-right" => Some(Self::Notch(Notch::Right)),
            _ => None,
        }
    }
}

/// What Emacs saw the button do, which is the third thing `cooked--send-mouse-report'
/// is told.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Press,
    Release,
    Motion,
}

impl Kind {
    /// The kind NAME names, or `None` for a symbol that is not one of the three.
    pub(crate) fn parse(name: &str) -> Option<Self> {
        match name {
            "press" => Some(Self::Press),
            "release" => Some(Self::Release),
            "motion" => Some(Self::Motion),
            _ => None,
        }
    }
}

/// One mouse report, as what the pointer did rather than as the byte that spells it.
///
/// The combination is parsed once, here, so that nothing below can hold a report no mouse
/// could produce: a notch cannot be let go of or dragged, and a press names a button.
/// Which also means the tracking mode is asked about this rather than about bits masked
/// back out of a number -- the motion bit and the wheel bit are in the byte because that
/// is where xterm's tables put them, not because they are a second opinion to be re-read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Report {
    /// A button going down, or the same button coming up. Every tracking mode reports
    /// these; it is what asking for the mouse at all means.
    Press { held: Held, down: bool },
    /// A wheel notch, which is always a press: applications discard a release of buttons
    /// 64 to 67, so a notch spelled as one would simply vanish. Reported under every mode
    /// for the same reason a press is.
    Wheel(Notch),
    /// The pointer moving, over the button being dragged -- which 1002 and 1003 report
    /// and 1000 does not -- or over nothing at all, which only 1003 asks for.
    Motion(Option<Held>),
}

impl Held {
    /// The low two bits xterm numbers this button with.
    fn bits(self) -> u8 {
        match self {
            Self::Left => 0,
            Self::Middle => 1,
            Self::Right => 2,
        }
    }
}

impl Notch {
    /// The low two bits under [`Report::WHEEL`], which make 64 to 67.
    fn bits(self) -> u8 {
        match self {
            Self::Up => 0,
            Self::Down => 1,
            Self::Left => 2,
            Self::Right => 3,
        }
    }
}

impl Report {
    /// The button number standing for "no button", which is both what X10 substitutes for
    /// a release and what motion with nothing held reports.
    const NONE: u8 = 3;
    /// The bit saying the report is motion rather than a press or a release.
    const MOTION: u8 = 32;
    /// The bit moving the low two bits into the wheel's notches, 64 to 67.
    const WHEEL: u8 = 64;
    /// The bit xterm's tables call shift. Never set: `S-down-mouse-1' running
    /// `mouse-drag-region' is the universal way to select text out of a program that has
    /// taken the mouse, and xterm, kitty and foot all keep Shift back for it, so no
    /// program can be relying on seeing it. `cooked--mouse-map' claims the shifted button
    /// for Emacs rather than for the child, and this is the other half of that decision.
    const SHIFT: u8 = 4;
    /// The bit xterm's tables call meta, which is the modifier Emacs calls Meta.
    const META: u8 = 8;
    const CONTROL: u8 = 16;
    /// The three modifier bits: the only ones a release still carries, because they
    /// describe the keyboard rather than the gesture.
    const MODIFIERS: u8 = Self::SHIFT | Self::META | Self::CONTROL;

    /// BUTTON doing KIND, or `None` for a combination no mouse can produce.
    ///
    /// That is a wheel notch released or dragged, and a press or a release of no button:
    /// `None` as the button means the pointer moving with nothing held, which is the one
    /// report that names no button at all.
    pub(crate) fn new(button: Option<Button>, kind: Kind) -> Option<Self> {
        match (button, kind) {
            (Some(Button::Held(held)), Kind::Press) => Some(Self::Press { held, down: true }),
            (Some(Button::Held(held)), Kind::Release) => Some(Self::Press { held, down: false }),
            (Some(Button::Held(held)), Kind::Motion) => Some(Self::Motion(Some(held))),
            (Some(Button::Notch(notch)), Kind::Press) => Some(Self::Wheel(notch)),
            (None, Kind::Motion) => Some(Self::Motion(None)),
            (Some(Button::Notch(_)), Kind::Release | Kind::Motion) => None,
            (None, Kind::Press | Kind::Release) => None,
        }
    }

    /// Whether the wire form says a button is down, which is what the final byte of an
    /// SGR report spells and what X10 decides its substitution from.
    ///
    /// Motion and a notch are both presses: the pointer moving with a button held is that
    /// button still down, and a notch spelled as a release is a report applications throw
    /// away.
    fn pressed(self) -> bool {
        match self {
            Self::Press { down, .. } => down,
            Self::Wheel(_) | Self::Motion(_) => true,
        }
    }

    /// The bits MODS adds to the button number.
    ///
    /// Shift is dropped rather than spelled; see [`Report::SHIFT`]. So are Super and
    /// Hyper, which this encoding has no bit for at all, and so is everything else
    /// `event-modifiers' reports about a mouse event -- `down', `drag' and `click' say
    /// what the gesture was, which [`Kind`] already carries.
    fn modifier_bits(mods: Modifiers) -> u8 {
        let mut bits = 0;
        if mods.holds(Modifiers::META) {
            bits |= Self::META;
        }
        if mods.holds(Modifiers::CONTROL) {
            bits |= Self::CONTROL;
        }
        bits
    }

    /// The xterm button byte for this report held with MODS.
    ///
    /// The byte is not a button number with flags beside it; the flags are *in* it, and
    /// xterm's own tables are written that way. Which is also the number an SGR report
    /// prints: 1006 puts the byte on the wire as decimal digits, modifiers, motion bit
    /// and all.
    fn bits(self, mods: Modifiers) -> u8 {
        let base = match self {
            Self::Press { held, .. } => held.bits(),
            Self::Wheel(notch) => Self::WHEEL | notch.bits(),
            Self::Motion(held) => Self::MOTION | held.map_or(Self::NONE, Held::bits),
        };
        base | Self::modifier_bits(mods)
    }

    /// The number an X10 report names: the byte for a press and, for a release,
    /// [`Report::NONE`] with whatever of [`Report::MODIFIERS`] was held.
    ///
    /// The original form has no field for the button being let go of, so every release
    /// names no button -- which is why a wheel notch released cannot say which way the
    /// wheel turned, and why `Mouse` prefers 1006 wherever the child has offered it. xterm's
    /// ctlseqs still has the modifiers surviving a release, so shift, meta and control are
    /// kept; the motion bit, the wheel bit and 128 are not, since none of them describes the
    /// keyboard and a wheel byte kept whole would report a release as a notch.
    fn x10_bits(self, mods: Modifiers) -> u8 {
        let bits = self.bits(mods);
        if self.pressed() {
            bits
        } else {
            (bits & Self::MODIFIERS) | Self::NONE
        }
    }
}

impl Mouse {
    /// Whether the mode the child holds now reports REPORT at all.
    ///
    /// This is the half of the stale-mirror window that `enabled` alone does not close.
    /// Lisp decides whether to follow the pointer from `cooked--mouse-state`, which is
    /// only as fresh as the last drain, so a child that narrowed 1003 to 1002 -- or 1002
    /// to 1000 -- goes on receiving motion it never asked for until Emacs next drains.
    /// A child reading raw bytes does not ignore an unasked-for report; it reads it as
    /// whatever the sequence means to it. So the question is asked here, against the
    /// mode the child itself set, and a report no mode covers is dropped rather than
    /// sent.
    fn covers(self, report: Report) -> bool {
        match (self.tracking, report) {
            (MouseTracking::Off, _) => false,
            (_, Report::Press { .. } | Report::Wheel(_)) => true,
            (MouseTracking::Drag | MouseTracking::Motion, Report::Motion(Some(_))) => true,
            (MouseTracking::Motion, Report::Motion(None)) => true,
            (MouseTracking::Click, Report::Motion(_)) => false,
            (MouseTracking::Drag, Report::Motion(None)) => false,
        }
    }
}

impl Term {
    /// REPORT at ROW/COL, spelled as this child asked and measured against the cell size
    /// it was last told about, or `None` if it does not want the mouse.
    ///
    /// The two readings are taken together, which is the point of asking here at all: the
    /// format and the cell size both belong to the child, and a report built from one of
    /// them as it was at the last drain and the other as it is now names a place neither
    /// end agrees on. `None` is the same answer given for the same reason -- the child
    /// turned tracking off, or narrowed it past what REPORT says the pointer did, after
    /// Emacs decided a click was its to hear, and the click belongs to nobody. See
    /// [`Mouse::covers`].
    pub(crate) fn mouse_report(
        &self,
        report: Report,
        mods: Modifiers,
        row: u64,
        col: u64,
        offset: Option<(i64, i64)>,
    ) -> Option<Vec<u8>> {
        let mouse = self.mouse();
        mouse
            .covers(report)
            .then(|| mouse.report(report, mods, row, col, offset, self.cell_metrics()))
    }
}

impl Mouse {
    /// REPORT at ROW/COL, held with MODS, as the child spelled it.
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
        report: Report,
        mods: Modifiers,
        row: u64,
        col: u64,
        offset: Option<(i64, i64)>,
        cell: Option<CellMetrics>,
    ) -> Vec<u8> {
        let pressed = report.pressed();
        match self.format {
            MouseFormat::SgrPixels => {
                let (dx, dy) = cell.and(offset).unwrap_or((0, 0));
                let width = cell.map_or(1, |c| u64::from(c.width()));
                let height = cell.map_or(1, |c| u64::from(c.height()));
                let x = col.saturating_mul(width).saturating_add(dx.max(0) as u64);
                let y = row
                    .saturating_mul(height)
                    .saturating_add(dy.clamp(0, height as i64 - 1) as u64);
                sgr(
                    report.bits(mods),
                    x.saturating_add(1),
                    y.saturating_add(1),
                    pressed,
                )
            }
            MouseFormat::Sgr => sgr(
                report.bits(mods),
                col.saturating_add(1),
                row.saturating_add(1),
                pressed,
            ),
            MouseFormat::X10 => x10(report.x10_bits(mods), row, col),
        }
    }
}

/// `ESC [ < BUTTON ; X ; Y M`, or `m` for a release: DEC mode 1006.
///
/// The `<` is the whole of what tells the child it is reading an SGR report rather than
/// an X10 one, and the final byte is the whole of what tells it a button went up -- which
/// is the point of the form: X10 reports every release as button 3, so a wheel notch let
/// go of cannot say which way the wheel turned.
fn sgr(button: u8, x: u64, y: u64, pressed: bool) -> Vec<u8> {
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
fn x10(button: u8, row: u64, col: u64) -> Vec<u8> {
    let field = |n: u64| {
        char::from_u32(u32::try_from(n).unwrap_or(u32::MAX)).unwrap_or(char::REPLACEMENT_CHARACTER)
    };
    let named = u32::from(button);
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

    /// The left button going down, which is the ordinary click every byte test below is
    /// written about, and the same button coming up.
    const DOWN: Report = Report::Press {
        held: Held::Left,
        down: true,
    };
    const UP: Report = Report::Press {
        held: Held::Left,
        down: false,
    };
    /// One notch of the wheel upwards, which is button 64.
    const WHEEL_UP: Report = Report::Wheel(Notch::Up);
    /// No modifier held, which is what nearly every report carries.
    const BARE: Modifiers = Modifiers::NONE;

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
        assert_eq!(m.report(DOWN, BARE, 4, 9, None, None), b"\x1b[<0;10;5M");
        assert_eq!(m.report(UP, BARE, 4, 9, None, None), b"\x1b[<0;10;5m");
        assert_eq!(m.report(WHEEL_UP, BARE, 0, 0, None, None), b"\x1b[<64;1;1M");
        // A wheel notch is a press. Emacs calls a notch a click, and a report that
        // went out as `m' would reach the child and be discarded: applications throw
        // away a release of buttons 64 and 65.
        assert_eq!(m.report(WHEEL_UP, BARE, 3, 5, None, None), b"\x1b[<64;6;4M");
    }

    #[test]
    fn x10_biases_by_thirty_two_and_names_no_button_on_release() {
        let m = mouse(MouseFormat::X10);
        assert_eq!(m.report(DOWN, BARE, 0, 0, None, None), b"\x1b[M !!");
        assert_eq!(m.report(DOWN, BARE, 2, 4, None, None), b"\x1b[M %#");
        // Every release is button 3, so two buttons let go of are one report.
        let right = Report::Press {
            held: Held::Right,
            down: false,
        };
        assert_eq!(m.report(UP, BARE, 0, 0, None, None), b"\x1b[M#!!");
        assert_eq!(
            m.report(right, BARE, 3, 5, None, None),
            m.report(UP, BARE, 3, 5, None, None)
        );
        assert_ne!(
            m.report(DOWN, BARE, 3, 5, None, None),
            m.report(
                Report::Press {
                    held: Held::Right,
                    down: true
                },
                BARE,
                3,
                5,
                None,
                None
            )
        );
    }

    #[test]
    fn an_x10_release_keeps_the_modifiers_and_nothing_else() {
        let m = mouse(MouseFormat::X10);
        let held = |mods| m.report(UP, mods, 0, 0, None, None);
        // A plain release still names no button.
        assert_eq!(held(BARE), b"\x1b[M#!!");
        // A control-click released keeps the control bit, and a meta-click the meta one.
        assert_eq!(held(Modifiers::CONTROL), b"\x1b[M3!!");
        assert_eq!(held(Modifiers::META), b"\x1b[M+!!");
        assert_eq!(held(Modifiers::META.with(Modifiers::CONTROL)), b"\x1b[M;!!");
        // A drag released, and a notch let go of, are reports no mouse can make: the
        // motion bit and the wheel bit surviving a release is what the mask above is
        // there to prevent, and neither can now be built to be masked.
        assert!(Report::new(Some(Button::Notch(Notch::Up)), Kind::Release).is_none());
        assert!(Report::Motion(Some(Held::Left)).pressed());
    }

    #[test]
    fn x10_past_the_223_column_limit_spells_the_field_in_utf8() {
        let m = mouse(MouseFormat::X10);
        // Column 94 is the last that biases to a single byte, 127.
        assert_eq!(m.report(DOWN, BARE, 0, 94, None, None), b"\x1b[M \x7f!");
        // One further is U+0080, which reaches the pty as the two bytes of its UTF-8.
        assert_eq!(m.report(DOWN, BARE, 0, 95, None, None), b"\x1b[M \xc2\x80!");
        // And 223, the column the form is usually said to stop at, is U+00FF.
        assert_eq!(
            m.report(DOWN, BARE, 0, 222, None, None),
            b"\x1b[M \xc3\xbf!"
        );
    }

    #[test]
    fn pixels_scale_the_reported_cell_and_add_the_offset() {
        let m = mouse(MouseFormat::SgrPixels);
        let c = cell(9, 20);
        // Row 3, column 5, four pixels right and seven down inside it.
        assert_eq!(
            m.report(DOWN, BARE, 3, 5, Some((4, 7)), c),
            b"\x1b[<0;50;68M".as_slice()
        );
        assert_eq!(
            m.report(UP, BARE, 3, 5, Some((4, 7)), c),
            b"\x1b[<0;50;68m".as_slice()
        );
        // The child divides by the size it was told, and lands back in the cell.
        assert_eq!((50 - 1) / 9, 5);
        assert_eq!((68 - 1) / 20, 3);
        // No offset is a position standing in for the pointer: the cell's corner.
        assert_eq!(
            m.report(WHEEL_UP, BARE, 3, 5, None, c),
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
            m.report(DOWN, BARE, 3, 5, Some((4, 25)), c),
            b"\x1b[<0;50;80M".as_slice()
        );
        // An image's ascent can put the pointer above the row's top; a wide glyph's own
        // offset is real and passes through.
        assert_eq!(
            m.report(DOWN, BARE, 3, 5, Some((14, -2)), c),
            b"\x1b[<0;60;61M".as_slice()
        );
    }

    #[test]
    fn a_frame_with_no_cell_size_reports_cells_counted_from_one() {
        let m = mouse(MouseFormat::SgrPixels);
        assert_eq!(
            m.report(DOWN, BARE, 3, 5, Some((4, 7)), None),
            b"\x1b[<0;6;4M".as_slice()
        );
    }

    #[test]
    fn a_one_pixel_cell_leaves_no_room_for_an_offset() {
        let m = mouse(MouseFormat::SgrPixels);
        assert_eq!(
            m.report(DOWN, BARE, 3, 5, Some((7, 7)), cell(1, 1)),
            b"\x1b[<0;13;4M".as_slice(),
            "dy clamps to zero, the only pixel the row has; dx has no clamp"
        );
    }

    /// The four things a report can say the pointer did, which are the four the tracking
    /// modes speak of: a press, a wheel notch, the pointer moving with a button held and
    /// the pointer moving with nothing held.
    fn reports() -> [Report; 4] {
        [
            DOWN,
            WHEEL_UP,
            Report::Motion(Some(Held::Left)),
            Report::Motion(None),
        ]
    }

    #[test]
    fn a_report_no_mouse_could_make_is_refused() {
        // A notch is over the instant it happens: it cannot come up and cannot be
        // dragged, and a byte saying so would be a scroll a tracking mode could refuse.
        assert!(Report::new(Some(Button::Notch(Notch::Down)), Kind::Release).is_none());
        assert!(Report::new(Some(Button::Notch(Notch::Down)), Kind::Motion).is_none());
        // Only the pointer moving names no button at all.
        assert!(Report::new(None, Kind::Press).is_none());
        assert!(Report::new(None, Kind::Release).is_none());
        assert_eq!(Report::new(None, Kind::Motion), Some(Report::Motion(None)));
    }

    #[test]
    fn a_tracking_mode_covers_the_reports_it_asked_for() {
        let covered = |tracking| {
            let mouse = Mouse {
                tracking,
                format: MouseFormat::Sgr,
            };
            reports().map(|report| mouse.covers(report))
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

    /// Every button, kind and modifier Lisp can send, against the byte the numeric
    /// crossing computed for it before the arguments became symbols.
    ///
    /// The old arithmetic was Lisp's: a button table naming 0 to 2 and 64 to 67, a
    /// motion bit of 32 added to the button held or to 3 for none, and a modifier table
    /// adding meta 8 and control 16 -- never shift, which stays Emacs'. Spelled out here
    /// so that the symbolic path is pinned to the bytes children were already reading.
    #[test]
    fn the_symbolic_crossing_spells_the_byte_the_numeric_one_did() {
        const MOTION_BIT: u8 = 32;
        const NO_BUTTON: u8 = 3;
        let buttons = [
            (Button::Held(Held::Left), 0),
            (Button::Held(Held::Middle), 1),
            (Button::Held(Held::Right), 2),
            (Button::Notch(Notch::Up), 64),
            (Button::Notch(Notch::Down), 65),
            (Button::Notch(Notch::Left), 66),
            (Button::Notch(Notch::Right), 67),
        ];
        let modifiers = [
            (Modifiers::NONE, 0),
            (Modifiers::META, 8),
            (Modifiers::CONTROL, 16),
            (Modifiers::META.with(Modifiers::CONTROL), 24),
            // Shift added nothing to the old byte either.
            (Modifiers::SHIFT, 0),
            (Modifiers::SHIFT.with(Modifiers::CONTROL), 16),
        ];
        for (button, number) in buttons {
            for kind in [Kind::Press, Kind::Release, Kind::Motion] {
                let Some(report) = Report::new(Some(button), kind) else {
                    continue;
                };
                let base = match kind {
                    Kind::Motion => MOTION_BIT + number,
                    Kind::Press | Kind::Release => number,
                };
                for (mods, bits) in modifiers {
                    assert_eq!(report.bits(mods), base + bits, "{report:?} with {mods:?}");
                }
            }
        }
        // And the pointer moving with nothing held, which the old path spelled as the
        // motion bit over the button number standing for none.
        let hover = Report::new(None, Kind::Motion).expect("motion names no button");
        for (mods, bits) in modifiers {
            assert_eq!(hover.bits(mods), MOTION_BIT + NO_BUTTON + bits, "{mods:?}");
        }
    }
}
