//! Sixel, decoded to pixels.
//!
//! A sixel image is a DCS string — `ESC P <params> q <body> ESC \` — whose body spells
//! out a bitmap six pixels at a time: each character from `?` to `~` carries six vertical
//! pixels as the low six bits of `byte - 0x3F`, and a row of them is a *band* six pixels
//! tall. `$` returns to the left margin of the current band, `-` starts the next one,
//! `#` selects or defines a colour, `!` repeats the next character, and `"` declares the
//! canvas up front.
//!
//! This is the second producer of the same [`ImageData`](super::image::ImageData) the
//! kitty protocol feeds, and deliberately so: everything downstream of "here are some
//! pixels" — interning, content addressing, per-cell placement, Emacs' ownership of the
//! lifetime — already exists and needed nothing added for a second format.
//!
//! **Untouched pixels come out transparent**, whichever background mode the introducer
//! asked for. The spec says they take "the background colour", and in a terminal that
//! renders sixels itself the terminal knows what that is. Here it is Emacs': the picture
//! is composited over buffer text whose face supplies the background, and alpha is how
//! that background shows through. Guessing a colour and painting it would put a grey
//! rectangle behind a picture the user expects to sit on their own background, and would
//! be wrong again the moment they changed theme.
//!
//! Two passes over the body, because the size is not reliably known in front of it. `"`
//! is optional, encoders that do emit it sometimes understate it, and the alternative to
//! measuring is reallocating a bitmap mid-decode as it grows to the right. The first pass
//! allocates nothing.

/// The most pixels one sixel image may decode to.
///
/// The same bound the kitty path enforces by different means: a decoded picture is RGBA,
/// and this is [`MAX_PAYLOAD`](super::kitty::MAX_PAYLOAD) bytes of it. Sixel needs the
/// check more than kitty does, because `!` is a compressor — five bytes of `!9999~`
/// name ten thousand pixels — so the body's length bounds the output only weakly.
use super::image::PixelSize;
use super::png::{PixelFormat, Pixels};

pub(crate) const MAX_PIXELS: usize = super::kitty::MAX_PAYLOAD / 4;

/// A decoded sixel is just [`Pixels`]: RGBA and a size.
///
/// An alias rather than its own struct, because it was one -- with `width`/`height`
/// spelled as two fields here, as a `(u32, u32)` tuple in the caller, and as a third
/// arrangement again in kitty -- and every one of them ended in the same encode.
pub(crate) type Bitmap = Pixels;

/// The VT340's colour registers, which a stream may use without defining anything.
///
/// In the percentages the format itself speaks, so the table reads like the hardware
/// manual it comes from rather than like something converted twice.
const DEFAULT_PALETTE: [(u8, u8, u8); 16] = [
    (0, 0, 0),
    (20, 20, 80),
    (80, 13, 13),
    (20, 80, 20),
    (80, 20, 80),
    (20, 80, 80),
    (80, 80, 20),
    (53, 53, 53),
    (26, 26, 26),
    (33, 33, 60),
    (60, 26, 26),
    (33, 60, 33),
    (60, 33, 60),
    (33, 60, 60),
    (60, 60, 33),
    (80, 80, 80),
];

/// How many colour registers a stream may address.
const PALETTE_SIZE: usize = 256;

/// Decode the body of a sixel DCS string.
///
/// `None` when the body describes no pixels at all, or more of them than [`MAX_PIXELS`]
/// allows. A body with unrecognised bytes in it is not an error: sixel has accumulated
/// private extensions, and the readable parts of a picture are worth more than a refusal.
pub(crate) fn decode(body: &[u8]) -> Option<Bitmap> {
    let size = measure(body)?;
    let mut bitmap = Pixels::new(
        size,
        PixelFormat::Rgba,
        vec![0; 4 * size.w as usize * size.h as usize],
    );
    render(body, &mut bitmap);
    Some(bitmap)
}

/// First pass: how large a canvas the body needs, without allocating one.
///
/// The declared size from `"` is a floor rather than the answer. Encoders emit it
/// accurately most of the time, but a stream whose data runs past it would otherwise be
/// silently cropped, and one that overstates it would leave a border — so the canvas is
/// whichever is larger, and [`render`] clips to it either way.
fn measure(body: &[u8]) -> Option<PixelSize> {
    let (mut width, mut height) = (0u32, 0u32);
    let (mut x, mut band) = (0u32, 0u32);
    for token in Tokens::new(body) {
        match token {
            Token::Data(bits, repeat) => {
                x = x.saturating_add(repeat);
                width = width.max(x);
                // A band contributes height only for the rows it actually sets, so a
                // picture whose last band uses two of its six rows is not padded to six.
                if bits != 0 {
                    let top = 6 * band + top_bit(bits) + 1;
                    height = height.max(top);
                }
            }
            Token::CarriageReturn => x = 0,
            Token::NewLine => {
                x = 0;
                band = band.saturating_add(1);
            }
            Token::Raster { ph, pv } => {
                width = width.max(ph);
                height = height.max(pv);
            }
            Token::Color(..) => {}
        }
    }
    let size = PixelSize::new(width, height);
    if size.is_empty() {
        return None;
    }
    // `area` is `u64`, so two `u32`s cannot wrap it.
    if size.area() > MAX_PIXELS as u64 {
        return None;
    }
    Some(size)
}

/// Second pass: paint the body onto a canvas already the right size.
fn render(body: &[u8], bitmap: &mut Bitmap) {
    let mut palette = [[0u8; 4]; PALETTE_SIZE];
    for (slot, &(r, g, b)) in palette.iter_mut().zip(DEFAULT_PALETTE.iter()) {
        *slot = [scale(r), scale(g), scale(b), 255];
    }
    let mut pen = palette[0];
    let (mut x, mut band) = (0u32, 0u32);

    for token in Tokens::new(body) {
        match token {
            Token::Color(index, Some((r, g, b))) => {
                let rgba = [scale(r), scale(g), scale(b), 255];
                if let Some(slot) = palette.get_mut(index as usize) {
                    *slot = rgba;
                }
                // Defining a register also selects it, which is what lets an encoder
                // emit one `#n;2;r;g;b` per colour and then just draw.
                pen = rgba;
            }
            Token::Color(index, None) => {
                if let Some(&slot) = palette.get(index as usize) {
                    pen = slot;
                }
            }
            Token::Data(bits, repeat) => {
                // Clipped, though nothing reaching here through [`decode`] is clipped by
                // it: both passes walk the same tokens with the same arithmetic, and
                // `measure` takes the width from the widest `x` that walk reaches, so a
                // run always has canvas under it. The clip is what makes that a
                // *property* rather than a thing to be careful about -- a future change
                // to either pass degrades to a short picture instead of an index panic.
                //
                // Bounded by the canvas rather than by `repeat`, which is the same point
                // made about cost: `!` is a compressor, `!9999~` is five bytes naming ten
                // thousand pixels, and stepping the overrun one column at a time would
                // tie the work to that count -- safe only while `measure`'s own
                // `MAX_PIXELS` check holds, which is an invariant two functions away.
                let drawn = bitmap.size.w.saturating_sub(x).min(repeat);
                for _ in 0..drawn {
                    for row in 0..6 {
                        if bits & (1 << row) != 0 {
                            let y = 6 * band + row;
                            if y < bitmap.size.h {
                                let at = 4 * (y as usize * bitmap.size.w as usize + x as usize);
                                bitmap.data[at..at + 4].copy_from_slice(&pen);
                            }
                        }
                    }
                    x += 1;
                }
                // The rest is still *advanced* rather than clamped, so a run that
                // overruns the canvas does not fold the remainder of the band back on
                // top of what is already drawn. `drawn` is a `min` against `repeat`, so
                // the subtraction cannot go below zero.
                x = x.saturating_add(repeat - drawn);
            }
            Token::CarriageReturn => x = 0,
            Token::NewLine => {
                x = 0;
                band = band.saturating_add(1);
            }
            Token::Raster { .. } => {}
        }
    }
}

/// The index of the highest set bit of a six-bit sixel, which is its lowest pixel row.
fn top_bit(bits: u8) -> u32 {
    7 - bits.leading_zeros().min(7)
}

/// A colour component, from the format's 0..=100 to a byte.
fn scale(percent: u8) -> u8 {
    ((u32::from(percent.min(100)) * 255 + 50) / 100) as u8
}

/// One instruction from a sixel body.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Token {
    /// Six pixels, repeated this many times. `!Pn` folded in, so a repeat and a bare
    /// character are the same thing to both passes.
    Data(u8, u32),
    /// `#Pc` on its own selects; `#Pc;Pu;Px;Py;Pz` defines and then selects.
    Color(u16, Option<(u8, u8, u8)>),
    /// `"Pan;Pad;Ph;Pv` — only the size is of any use here.
    Raster { ph: u32, pv: u32 },
    /// `$`
    CarriageReturn,
    /// `-`
    NewLine,
}

struct Tokens<'a> {
    body: &'a [u8],
    at: usize,
}

impl<'a> Tokens<'a> {
    fn new(body: &'a [u8]) -> Self {
        Self { body, at: 0 }
    }

    /// Read `;`-separated decimal parameters, stopping at the first byte that is neither.
    ///
    /// Saturating rather than wrapping, and capped well below what any canvas could use,
    /// so a stream of digits names a large number rather than a small one by overflow.
    fn params(&mut self, out: &mut [u32]) -> usize {
        let mut count = 0;
        loop {
            let mut value = 0u32;
            let mut digits = 0;
            while let Some(&byte) = self.body.get(self.at) {
                if !byte.is_ascii_digit() {
                    break;
                }
                value = value
                    .saturating_mul(10)
                    .saturating_add(u32::from(byte - b'0'));
                self.at += 1;
                digits += 1;
            }
            if digits != 0 || count != 0 {
                if let Some(slot) = out.get_mut(count) {
                    *slot = value;
                }
                count += 1;
            }
            match self.body.get(self.at) {
                Some(b';') => self.at += 1,
                _ => return count.min(out.len()),
            }
        }
    }
}

impl Iterator for Tokens<'_> {
    type Item = Token;

    fn next(&mut self) -> Option<Token> {
        loop {
            let byte = *self.body.get(self.at)?;
            self.at += 1;
            match byte {
                b'?'..=b'~' => return Some(Token::Data(byte - 0x3F, 1)),
                b'$' => return Some(Token::CarriageReturn),
                b'-' => return Some(Token::NewLine),
                b'!' => {
                    let mut args = [0u32; 1];
                    self.params(&mut args);
                    let repeat = args[0];
                    let byte = *self.body.get(self.at)?;
                    self.at += 1;
                    if !(b'?'..=b'~').contains(&byte) {
                        // A repeat count introducing something that is not a sixel is a
                        // malformed stream; skip it rather than inventing pixels.
                        continue;
                    }
                    // `!0` is a repeat of nothing, not of one.
                    return Some(Token::Data(byte - 0x3F, repeat));
                }
                b'#' => {
                    let mut args = [0u32; 5];
                    let count = self.params(&mut args);
                    let index = args[0].min(u32::from(u16::MAX)) as u16;
                    // Only `Pu=2` — RGB — is honoured. `Pu=1` is HLS, which no encoder
                    // in circulation emits, and a wrong colour space is worse than the
                    // register's existing value.
                    if count >= 5 && args[1] == 2 {
                        let component = |v: u32| v.min(100) as u8;
                        return Some(Token::Color(
                            index,
                            Some((component(args[2]), component(args[3]), component(args[4]))),
                        ));
                    }
                    return Some(Token::Color(index, None));
                }
                b'"' => {
                    let mut args = [0u32; 4];
                    let count = self.params(&mut args);
                    // Pan and Pad are the aspect ratio, which Emacs does not need: the
                    // picture is scaled to a cell rectangle either way.
                    let (ph, pv) = if count >= 4 {
                        (args[2], args[3])
                    } else {
                        (0, 0)
                    };
                    return Some(Token::Raster { ph, pv });
                }
                // Whitespace is how encoders wrap long bodies, and anything else is a
                // private extension. Neither is a reason to lose the picture.
                _ => continue,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pixel at (X, Y) as RGBA.
    fn at(bitmap: &Bitmap, x: u32, y: u32) -> [u8; 4] {
        let i = 4 * (y as usize * bitmap.size.w as usize + x as usize);
        bitmap.data[i..i + 4].try_into().unwrap()
    }

    const RED: [u8; 4] = [255, 0, 0, 255];
    const BLUE: [u8; 4] = [0, 0, 255, 255];
    const CLEAR: [u8; 4] = [0, 0, 0, 0];

    #[test]
    fn a_sixel_character_is_six_pixels_bottom_bit_last() {
        // `@` is 0x40, so bits = 1: the top pixel of the band only.
        let bitmap = decode(b"#0;2;100;0;0@").unwrap();
        assert_eq!((bitmap.size.w, bitmap.size.h), (1, 1));
        assert_eq!(at(&bitmap, 0, 0), RED);

        // `~` is 0x7E, so bits = 0b111111: the whole band.
        let bitmap = decode(b"#0;2;100;0;0~").unwrap();
        assert_eq!((bitmap.size.w, bitmap.size.h), (1, 6));
        for y in 0..6 {
            assert_eq!(at(&bitmap, 0, y), RED, "row {y}");
        }
    }

    #[test]
    fn a_band_is_only_as_tall_as_the_rows_it_sets() {
        // 0b000011 — two rows of the six, so the picture is two pixels tall and not six.
        let bitmap = decode(b"#0;2;100;0;0B").unwrap();
        assert_eq!(bitmap.size.h, 2);
    }

    #[test]
    fn untouched_pixels_are_transparent_rather_than_a_guessed_background() {
        // `?` is zero bits: it advances without painting. Emacs composites the result
        // over buffer text, so the buffer's own background is what shows through -- which
        // is what "the background colour" means when the terminal does not own it.
        let bitmap = decode(b"#0;2;100;0;0~?~").unwrap();
        assert_eq!((bitmap.size.w, bitmap.size.h), (3, 6));
        assert_eq!(at(&bitmap, 0, 0), RED);
        assert_eq!(at(&bitmap, 1, 0), CLEAR);
        assert_eq!(at(&bitmap, 2, 0), RED);
    }

    #[test]
    fn a_repeat_is_the_same_as_writing_the_character_out() {
        let repeated = decode(b"#0;2;100;0;0!4~").unwrap();
        let spelled = decode(b"#0;2;100;0;0~~~~").unwrap();
        assert_eq!(repeated, spelled);
        assert_eq!(repeated.size.w, 4);
    }

    #[test]
    fn a_repeat_of_zero_repeats_nothing() {
        // Not "at least once": `!0~` advances no columns at all.
        assert!(decode(b"#0;2;100;0;0!0~").is_none());
        let bitmap = decode(b"#0;2;100;0;0~!0~~").unwrap();
        assert_eq!(bitmap.size.w, 2);
    }

    #[test]
    fn dollar_returns_to_the_margin_and_dash_starts_a_band() {
        // Two colours over the same column: `$` rewinds without dropping down.
        let bitmap = decode(b"#0;2;100;0;0@$#1;2;0;0;100B").unwrap();
        assert_eq!((bitmap.size.w, bitmap.size.h), (1, 2));
        // The second pass overwrites the first pixel and adds the one below it.
        assert_eq!(at(&bitmap, 0, 0), BLUE);
        assert_eq!(at(&bitmap, 0, 1), BLUE);

        // `-` drops a whole band, so the second `@` lands on row 6 and not row 1.
        let bitmap = decode(b"#0;2;100;0;0@-@").unwrap();
        assert_eq!(bitmap.size.h, 7);
        assert_eq!(at(&bitmap, 0, 0), RED);
        assert_eq!(at(&bitmap, 0, 6), RED);
        assert_eq!(at(&bitmap, 0, 1), CLEAR);
    }

    #[test]
    fn defining_a_colour_register_also_selects_it() {
        // What lets an encoder emit one `#n;2;r;g;b` per colour and then just draw.
        let bitmap = decode(b"#7;2;0;0;100~").unwrap();
        assert_eq!(at(&bitmap, 0, 0), BLUE);
    }

    #[test]
    fn a_register_can_be_selected_again_after_being_defined() {
        let bitmap = decode(b"#1;2;100;0;0~#2;2;0;0;100~#1~").unwrap();
        assert_eq!(at(&bitmap, 0, 0), RED);
        assert_eq!(at(&bitmap, 1, 0), BLUE);
        assert_eq!(at(&bitmap, 2, 0), RED);
    }

    #[test]
    fn the_default_palette_is_available_without_defining_anything() {
        // Register 1 of the VT340 is blue-ish; a stream may use it undefined.
        let bitmap = decode(b"#1~").unwrap();
        assert_eq!(at(&bitmap, 0, 0), [51, 51, 204, 255]);
    }

    #[test]
    fn raster_attributes_set_a_floor_for_the_canvas_not_the_answer() {
        // Declared larger than the data: the border is kept, because an encoder saying
        // how big the picture is is more likely right than the extent of its ink.
        let bitmap = decode(b"\"1;1;10;12#0;2;100;0;0~").unwrap();
        assert_eq!((bitmap.size.w, bitmap.size.h), (10, 12));
        assert_eq!(at(&bitmap, 0, 0), RED);
        assert_eq!(at(&bitmap, 9, 11), CLEAR);

        // Declared smaller than the data: the data wins, rather than being cropped.
        let bitmap = decode(b"\"1;1;1;1#0;2;100;0;0~~~").unwrap();
        assert_eq!((bitmap.size.w, bitmap.size.h), (3, 6));
    }

    #[test]
    fn a_run_past_the_right_edge_is_clipped_rather_than_folded_back() {
        // `render` is exercised directly because `decode` cannot produce this: `measure`
        // sizes the canvas from the same token walk, so a run always has canvas under it.
        // That is exactly why the clip is worth a test of its own -- it is the thing
        // keeping an undersized canvas a short picture rather than an index panic.
        let size = PixelSize::new(2, 6);
        let mut bitmap = Pixels::new(size, PixelFormat::Rgba, vec![0; 4 * 2 * 6]);
        render(b"#0;2;100;0;0!5~", &mut bitmap);

        // The two columns that exist are painted, and the run's remaining three neither
        // panicked nor wrapped back onto the start of the band.
        assert_eq!(at(&bitmap, 0, 0), RED);
        assert_eq!(at(&bitmap, 1, 5), RED);

        // And the overrun still *advances*: a `$` would be needed to get back to column
        // zero, so a second run after it stays off the canvas rather than overwriting.
        render(b"#0;2;100;0;0!5~#0;2;0;0;100~", &mut bitmap);
        assert_eq!(at(&bitmap, 0, 0), RED);
        assert_eq!(at(&bitmap, 1, 0), RED);
    }

    #[test]
    fn a_body_with_no_pixels_in_it_is_not_a_picture() {
        assert!(decode(b"").is_none());
        assert!(decode(b"#0;2;100;0;0").is_none());
        // All-transparent has width but no height: nothing sets a row, so there is no
        // row to be the bottom of the picture. Refusing it costs nothing -- it would
        // have rendered as the blank cells it already occupies -- and it keeps the
        // height rule to one sentence: a band is as tall as the rows it sets.
        assert!(decode(b"???").is_none());
        // Unless something says otherwise: a declared canvas is a picture even if the
        // ink never arrives, which is how an encoder spells a deliberately blank frame.
        assert!(decode(b"\"1;1;3;3???").is_some());
    }

    #[test]
    fn a_picture_larger_than_the_cap_is_refused_rather_than_allocated() {
        // `!` is a compressor: this is eleven bytes naming four billion pixels, which is
        // the sixel spelling of the geometry attack the kitty path already refuses.
        assert!(decode(b"!999999~-!999999~").is_none());
        // The bound is on the product, so a legal picture of the same width is fine.
        let wide = decode(b"!2000~").unwrap();
        assert_eq!((wide.size.w, wide.size.h), (2000, 6));
    }

    #[test]
    fn unknown_bytes_do_not_cost_the_picture() {
        // Encoders wrap long bodies on whitespace, and the format has accumulated
        // private extensions; the readable part is worth more than a refusal.
        let bitmap = decode(b"#0;2;100;0;0~\n~\r~").unwrap();
        assert_eq!(bitmap.size.w, 3);
    }

    #[test]
    fn a_truncated_colour_command_does_not_swallow_the_data_after_it() {
        // `#1;2;0` is missing components: it selects register 1 rather than defining it,
        // and the sixel after it still draws.
        let bitmap = decode(b"#1;2;0~").unwrap();
        assert_eq!(bitmap.size.w, 1);
        assert_eq!(at(&bitmap, 0, 0), [51, 51, 204, 255]);
    }

    #[test]
    fn a_bang_at_the_very_end_is_not_a_panic() {
        assert!(decode(b"#0;2;100;0;0~!").is_some());
        assert!(decode(b"!").is_none());
        assert!(decode(b"#").is_none());
        assert!(decode(b"\"").is_none());
    }

    #[test]
    fn the_top_bit_of_a_sixel_names_its_lowest_row() {
        assert_eq!(top_bit(0b000001), 0);
        assert_eq!(top_bit(0b000010), 1);
        assert_eq!(top_bit(0b100000), 5);
        assert_eq!(top_bit(0b111111), 5);
    }
}
