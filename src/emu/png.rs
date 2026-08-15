//! Reading and writing image bytes: what a file says it is, and how raw pixels become one.
//!
//! Everything here is bytes in, bytes out. Nothing in this module knows about terminals,
//! grids, cells or sessions, and that is the argument for it existing rather than an
//! accident of where the code landed: [`sniff`] answers "what is this file, and how big"
//! from the header alone, and [`Pixels::encode`] answers "what can Emacs decode" from a
//! size, a layout and a buffer. Both used to sit beside the store in
//! [`image`](super::image), where a third of the file was deflate blocks and CRC tables
//! the store never called and could not have used.
//!
//! Encoding and decoding are one module rather than two because they are one concern: the
//! sniffers read the same headers the encoder writes, and the encoder is what the header
//! tests build their inputs with -- `png_dimensions` is checked against a PNG this file
//! produced, which is a test neither half could write alone.
//!
//! What stayed behind is everything with an opinion about the grid: the cell geometry,
//! the placements, and [`ImageStore`](super::image::ImageStore) itself. Two names cross
//! the seam, and both come this way -- [`PixelSize`], because a header states one and an
//! encoder is handed one, and [`ImageFormat`], because naming the bytes is the other half
//! of what the encoder returns. Note which of the near-identical pair went where:
//! [`PixelSize`] is geometry and belongs with the geometry, while [`PixelFormat`] is a
//! byte layout and has no meaning outside this file.
//!
//! PNG dominates and so names the module. It is the only format written from scratch --
//! signature, stored deflate blocks, adler32 and CRC-32, which is the whole of the bulk
//! below -- where P6 is a header prepended to bytes that already exist, and JPEG and GIF
//! are read but never written.

use super::image::{ImageFormat, PixelSize};

/// Read a big-endian `u16` at `at`, or `None` if the bytes are not there.
fn be_u16(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?))
}

/// Read a big-endian `u32` at `at`, or `None` if the bytes are not there.
fn be_u32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

/// The eight bytes every PNG opens with.
const PNG_MAGIC: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

/// A PNG's intrinsic size, read from the IHDR its own header requires.
///
/// Clients routinely send `f=100` without `s=`/`v=`, because a PNG carries its size and
/// the protocol does not ask them to repeat it. The alternative to reading it here is
/// refusing those transmissions, or guessing — and the cell rectangle has to be settled
/// before the image is laid into the grid, long before Emacs decodes anything.
pub(crate) fn png_dimensions(bytes: &[u8]) -> Option<PixelSize> {
    // 8-byte signature, then a chunk header of length and tag, then IHDR's width/height.
    if !bytes.starts_with(PNG_MAGIC) || bytes.get(12..16)? != b"IHDR" {
        return None;
    }
    let size = PixelSize::new(be_u32(bytes, 16)?, be_u32(bytes, 20)?);
    (!size.is_empty()).then_some(size)
}

/// What an opaque image file is, and how big, read from its own header.
///
/// Needed because iTerm2's `OSC 1337` transmits a *file* with no format field: the
/// picture is whatever `imgcat` was pointed at. The kitty protocol never needs this --
/// `f=` says, and `f=100` is the only file format it carries -- so this exists for the
/// path that has to ask the bytes.
///
/// Only the three formats Emacs decodes natively are recognised. Anything else is
/// declined rather than passed through hopefully: a format Emacs cannot read renders as
/// nothing, and nothing is indistinguishable from a bug.
pub(crate) fn sniff(bytes: &[u8]) -> Option<(ImageFormat, PixelSize)> {
    if bytes.starts_with(PNG_MAGIC) {
        return Some((ImageFormat::Png, png_dimensions(bytes)?));
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        // The logical screen descriptor follows the six-byte signature, little-endian.
        let le = |at: usize| -> Option<u32> {
            Some(u32::from(u16::from_le_bytes(
                bytes.get(at..at + 2)?.try_into().ok()?,
            )))
        };
        let size = PixelSize::new(le(6)?, le(8)?);
        return (!size.is_empty()).then_some((ImageFormat::Gif, size));
    }
    if bytes.starts_with(b"\xff\xd8") {
        return Some((ImageFormat::Jpeg, jpeg_dimensions(bytes)?));
    }
    None
}

/// A JPEG's size, from the first start-of-frame segment.
///
/// JPEG states its dimensions in a segment rather than a header, so finding them means
/// walking the segment chain. Only as far as the frame header, which precedes the image
/// data in every file: this never reads the entropy-coded stream, whose length is not
/// declared and cannot be skipped.
fn jpeg_dimensions(bytes: &[u8]) -> Option<PixelSize> {
    let mut at = 2;
    loop {
        // Segments are `FF <marker>`, and any number of extra `FF`s may pad the gap.
        if *bytes.get(at)? != 0xFF {
            return None;
        }
        while *bytes.get(at)? == 0xFF {
            at += 1;
        }
        let marker = *bytes.get(at)?;
        at += 1;
        // The standalone markers carry no length to skip.
        if matches!(marker, 0x01 | 0xD0..=0xD9) {
            continue;
        }
        let length = usize::from(be_u16(bytes, at)?);
        // Every SOF but DHT (C4), JPG (C8) and DAC (CC), which share the range.
        if matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
            // Length, then one byte of sample precision, then height and width.
            let size = PixelSize::new(
                u32::from(be_u16(bytes, at + 5)?),
                u32::from(be_u16(bytes, at + 3)?),
            );
            return (!size.is_empty()).then_some(size);
        }
        // A segment that claims to be shorter than its own length field would not
        // advance, and a file of those would not terminate.
        at += length.max(2);
    }
}

/// How raw pixels are laid out, for the buffers that arrive as pixels rather than files.
///
/// PNG is deliberately not a variant: it is a *file* format, not a pixel layout, and
/// having it here is what made kitty's validator carry a `bytes_per_pixel` of 0 as a
/// sentinel for "not raw at all".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PixelFormat {
    Rgb,
    Rgba,
}

impl PixelFormat {
    pub(crate) fn bytes_per_pixel(self) -> u64 {
        match self {
            Self::Rgb => 3,
            Self::Rgba => 4,
        }
    }
}

/// A decoded image: a size, a layout, and the bytes.
///
/// The three producers of raw pixels -- sixel, kitty's `f=24`/`f=32` transmissions, and
/// anything else that decodes rather than forwards -- all ended in the same choice of
/// container, spelled out separately in each. [`Pixels::encode`] is now the one place
/// that rule lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Pixels {
    pub size: PixelSize,
    pub format: PixelFormat,
    pub data: Vec<u8>,
}

impl Pixels {
    pub(crate) fn new(size: PixelSize, format: PixelFormat, data: Vec<u8>) -> Self {
        Self { size, format, data }
    }

    /// How many bytes a complete buffer of this size and layout would be.
    ///
    /// `u64` so that a hostile size cannot wrap the product back into a plausible number.
    pub(crate) fn expected_len(&self) -> u64 {
        self.size.area() * self.format.bytes_per_pixel()
    }

    /// Bytes Emacs can decode, and what to call them.
    ///
    /// The one statement of the rule, so the three call sites do not each carry a copy:
    /// RGB becomes a P6, which costs a header, and RGBA has to become a PNG because
    /// Emacs' pbm reader has no alpha.
    pub(crate) fn encode(self) -> (ImageFormat, Vec<u8>) {
        match self.format {
            PixelFormat::Rgb => (ImageFormat::Ppm, ppm_from_rgb(self.size, &self.data)),
            PixelFormat::Rgba => (ImageFormat::Png, png_from_rgba(self.size, &self.data)),
        }
    }
}

/// Wrap RGB pixels as binary P6, which Emacs decodes with no image library at all.
///
/// The cheap target for anything arriving as raw pixels: a header and the bytes it
/// already has. No alpha, which is why RGBA takes the longer road below.
fn ppm_from_rgb(px: PixelSize, rgb: &[u8]) -> Vec<u8> {
    let header = format!("P6\n{} {}\n255\n", px.w, px.h);
    let wanted = (px.w as usize) * (px.h as usize) * 3;
    let mut out = Vec::with_capacity(header.len() + wanted);
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(&rgb[..wanted.min(rgb.len())]);
    // A short transmission is the child's error, not a reason to hand Emacs a file
    // whose header lies about its length. Pad rather than truncate the header.
    out.resize(header.len() + wanted, 0);
    out
}

/// Wrap RGBA pixels as a PNG, losslessly and without compressing.
///
/// Emacs' pbm reader has no alpha, so RGBA cannot take the cheap road — and a picture
/// with transparency composited against a guessed background is wrong in a way that
/// shows. A PNG it is, with deflate's *stored* blocks: no compression, no Huffman
/// tables, about as much code as the header itself, and the bytes are on their way to
/// an in-process decoder rather than down a wire.
fn png_from_rgba(px: PixelSize, rgba: &[u8]) -> Vec<u8> {
    let (w, h) = (px.w as usize, px.h as usize);
    // PNG scanlines carry a leading filter byte; 0 is "none".
    let mut raw = Vec::with_capacity(h * (1 + w * 4));
    for y in 0..h {
        raw.push(0);
        let row = y * w * 4;
        let end = (row + w * 4).min(rgba.len());
        if row < end {
            raw.extend_from_slice(&rgba[row..end]);
        }
        raw.resize((y + 1) * (1 + w * 4), 0);
    }

    let mut out = Vec::new();
    out.extend_from_slice(PNG_MAGIC);
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&px.w.to_be_bytes());
    ihdr.extend_from_slice(&px.h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]); // 8-bit, truecolour with alpha
    push_chunk(&mut out, b"IHDR", &ihdr);
    push_chunk(&mut out, b"IDAT", &zlib_stored(&raw));
    push_chunk(&mut out, b"IEND", &[]);
    out
}

fn push_chunk(out: &mut Vec<u8>, tag: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(tag);
    out.extend_from_slice(data);
    let mut crc = Crc32::default();
    crc.push(tag);
    crc.push(data);
    out.extend_from_slice(&crc.finish().to_be_bytes());
}

/// A zlib stream of stored (uncompressed) deflate blocks.
fn zlib_stored(data: &[u8]) -> Vec<u8> {
    let mut out = vec![0x78, 0x01]; // deflate, 32K window, no preset dictionary
    let mut chunks = data.chunks(0xFFFF).peekable();
    if data.is_empty() {
        out.extend_from_slice(&[0x01, 0x00, 0x00, 0xFF, 0xFF]);
    }
    while let Some(chunk) = chunks.next() {
        out.push(u8::from(chunks.peek().is_none()));
        let len = chunk.len() as u16;
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&(!len).to_le_bytes());
        out.extend_from_slice(chunk);
    }
    out.extend_from_slice(&adler32(data).to_be_bytes());
    out
}

/// Adler-32, with the modulo deferred rather than run per byte.
///
/// The definition is `a += byte; b += a`, both mod 65521, and spelling it that way costs
/// two divisions per byte — 7ms on a three-megabyte frame, on the reader thread, inside
/// the mutex Emacs takes to redisplay. 5552 is the most iterations that cannot overflow
/// `b` in `u32`, so the sums can run flat out and be reduced once per chunk; it is
/// zlib's own `NMAX`, and the whole reason this is two loops rather than one.
fn adler32(data: &[u8]) -> u32 {
    const NMAX: usize = 5552;
    let (mut a, mut b) = (1u32, 0u32);
    for chunk in data.chunks(NMAX) {
        for &byte in chunk {
            a += u32::from(byte);
            b += a;
        }
        a %= 65521;
        b %= 65521;
    }
    (b << 16) | a
}

/// CRC-32's slice-by-8 tables, built from the polynomial at compile time.
///
/// The first is the ordinary one: the eight shift-and-xor steps the bitwise loop ran per
/// byte, done once per byte value. Each later one is the previous advanced another byte,
/// which is what lets eight bytes be folded in at once.
///
/// A `const fn` rather than sixteen kilobytes of pasted magic numbers: the polynomial
/// stays in sight, and the tables cannot drift from it. Measured, because it is not
/// obvious: the *single* table is no faster than the bitwise loop it replaces. Every
/// byte's lookup is indexed by the previous byte's result, so the loop runs at the
/// latency of a dependent L1 load — about the same as eight shifts, which superscalar
/// hardware pipelines. Only breaking the chain, by indexing eight independent tables
/// with eight independent bytes, actually wins: 5.7ms to 1.3ms on a three-megabyte
/// picture.
const fn crc32_tables() -> [[u32; 256]; 8] {
    let mut tables = [[0u32; 256]; 8];
    let mut byte = 0;
    while byte < 256 {
        let mut crc = byte as u32;
        let mut bit = 0;
        while bit < 8 {
            crc = if crc & 1 == 0 {
                crc >> 1
            } else {
                (crc >> 1) ^ 0xEDB8_8320
            };
            bit += 1;
        }
        tables[0][byte] = crc;
        byte += 1;
    }
    let mut step = 1;
    while step < 8 {
        let mut byte = 0;
        while byte < 256 {
            let prev = tables[step - 1][byte];
            tables[step][byte] = (prev >> 8) ^ tables[0][(prev & 0xFF) as usize];
            byte += 1;
        }
        step += 1;
    }
    tables
}

static CRC32_TABLES: [[u32; 256]; 8] = crc32_tables();

#[derive(Default)]
struct Crc32(Option<u32>);

impl Crc32 {
    /// Eight bytes at a time out of [`CRC32_TABLES`], the odd tail one at a time.
    ///
    /// Every IDAT of every frame passes through here, and the bit-at-a-time loop this
    /// replaces cost 6ms on a three-megabyte picture — held, like the adler32 above it,
    /// inside the mutex Emacs takes to redisplay, so the reader thread was stalling the
    /// frame it was decoding.
    fn push(&mut self, data: &[u8]) {
        let mut crc = self.0.unwrap_or(0xFFFF_FFFF);
        let mut octets = data.chunks_exact(8);
        for octet in &mut octets {
            // The running CRC is xored into the low half before the fold, which is where
            // the byte-at-a-time version's `crc ^ byte` went.
            let lo = u32::from_le_bytes([octet[0], octet[1], octet[2], octet[3]]) ^ crc;
            let hi = u32::from_le_bytes([octet[4], octet[5], octet[6], octet[7]]);
            crc = CRC32_TABLES[7][(lo & 0xFF) as usize]
                ^ CRC32_TABLES[6][((lo >> 8) & 0xFF) as usize]
                ^ CRC32_TABLES[5][((lo >> 16) & 0xFF) as usize]
                ^ CRC32_TABLES[4][(lo >> 24) as usize]
                ^ CRC32_TABLES[3][(hi & 0xFF) as usize]
                ^ CRC32_TABLES[2][((hi >> 8) & 0xFF) as usize]
                ^ CRC32_TABLES[1][((hi >> 16) & 0xFF) as usize]
                ^ CRC32_TABLES[0][(hi >> 24) as usize];
        }
        for &byte in octets.remainder() {
            crc = (crc >> 8) ^ CRC32_TABLES[0][usize::from((crc as u8) ^ byte)];
        }
        self.0 = Some(crc);
    }

    fn finish(self) -> u32 {
        self.0.unwrap_or(0xFFFF_FFFF) ^ 0xFFFF_FFFF
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_dimensions_are_read_from_the_header() {
        let png = png_from_rgba(PixelSize::new(7, 3), &[0; 7 * 3 * 4]);
        assert_eq!(png_dimensions(&png), Some(PixelSize::new(7, 3)));
    }

    #[test]
    fn a_file_states_its_own_format_and_size() {
        let png = png_from_rgba(PixelSize::new(7, 3), &[0; 7 * 3 * 4]);
        assert_eq!(sniff(&png), Some((ImageFormat::Png, PixelSize::new(7, 3))));

        // A GIF's logical screen descriptor: signature, then width and height, little
        // endian. 0x0107 is 263, which no byte-order confusion could read as 7.
        let mut gif = b"GIF89a".to_vec();
        gif.extend_from_slice(&[7, 1, 3, 0, 0, 0, 0]);
        assert_eq!(
            sniff(&gif),
            Some((ImageFormat::Gif, PixelSize::new(263, 3)))
        );
        assert_eq!(
            sniff(b"GIF87a\x07\x00\x03\x00\x00\x00\x00").unwrap().1,
            PixelSize::new(7, 3)
        );
    }

    #[test]
    fn a_jpeg_states_its_size_in_a_segment_rather_than_a_header() {
        // SOI, a JFIF APP0 to be skipped over, then a baseline SOF0 carrying the size.
        let mut jpeg = vec![0xFF, 0xD8];
        jpeg.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]);
        jpeg.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08, 0, 3, 0, 7]);
        assert_eq!(
            sniff(&jpeg),
            Some((ImageFormat::Jpeg, PixelSize::new(7, 3)))
        );

        // The same, with a progressive SOF2 instead: the marker range matters, and DHT
        // (C4) sits inside it without being a frame header.
        let mut jpeg = vec![0xFF, 0xD8];
        jpeg.extend_from_slice(&[0xFF, 0xC4, 0x00, 0x04, 0x00, 0x00]);
        jpeg.extend_from_slice(&[0xFF, 0xC2, 0x00, 0x11, 0x08, 0, 3, 0, 7]);
        assert_eq!(
            sniff(&jpeg),
            Some((ImageFormat::Jpeg, PixelSize::new(7, 3)))
        );
    }

    #[test]
    fn a_truncated_or_looping_jpeg_terminates_rather_than_hanging() {
        // No frame header before the end.
        assert!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]).is_none());
        assert!(sniff(&[0xFF, 0xD8]).is_none());
        // A segment claiming to be shorter than its own length field would not advance,
        // and a file of those would never end.
        assert!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00, 0xFF, 0xE0, 0x00, 0x00]).is_none());
        // A zero size is not a picture.
        let mut jpeg = vec![0xFF, 0xD8];
        jpeg.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08, 0, 0, 0, 7]);
        assert!(sniff(&jpeg).is_none());
    }

    #[test]
    fn a_format_emacs_cannot_read_is_declined_rather_than_passed_through() {
        // A variant Emacs cannot render is a defect that only shows up on somebody
        // else's build, so the sniff is the place it is refused.
        assert!(sniff(b"BM\x00\x00\x00\x00").is_none());
        assert!(sniff(b"P6\n1 1\n255\n\0\0\0").is_none());
        assert!(sniff(b"").is_none());
        // Right signature, but a header too short to carry a size.
        assert!(sniff(b"GIF89a\x07").is_none());
    }

    #[test]
    fn something_that_is_not_a_png_has_no_dimensions() {
        assert_eq!(png_dimensions(b"P6\n1 1\n255\n\0\0\0"), None);
        assert_eq!(png_dimensions(b"short"), None);
    }

    #[test]
    fn ppm_states_its_own_dimensions() {
        let ppm = ppm_from_rgb(PixelSize::new(2, 1), &[1, 2, 3, 4, 5, 6]);
        assert!(ppm.starts_with(b"P6\n2 1\n255\n"));
        assert_eq!(&ppm[ppm.len() - 6..], &[1, 2, 3, 4, 5, 6]);
    }

    #[test]
    fn a_short_transmission_is_padded_not_misdeclared() {
        // Handing Emacs a header that lies about the length is worse than a black band.
        let ppm = ppm_from_rgb(PixelSize::new(2, 1), &[1, 2, 3]);
        assert_eq!(ppm.len(), "P6\n2 1\n255\n".len() + 6);
    }

    #[test]
    fn png_is_well_formed_enough_to_decode() {
        let png = png_from_rgba(PixelSize::new(2, 2), &[255; 16]);
        assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
        assert!(png.ends_with(b"\xaeB`\x82"), "IEND CRC");
        // Chunk lengths and tags in order, walking the file as a decoder would.
        let mut at = 8;
        let mut tags = Vec::new();
        while at + 8 <= png.len() {
            let len = u32::from_be_bytes(png[at..at + 4].try_into().unwrap()) as usize;
            tags.push(String::from_utf8_lossy(&png[at + 4..at + 8]).into_owned());
            at += 12 + len;
        }
        assert_eq!(tags, ["IHDR", "IDAT", "IEND"]);
        assert_eq!(at, png.len(), "chunks must tile the file exactly");
    }

    #[test]
    fn adler_matches_the_reference_value() {
        // zlib's documented example, so the checksum is not merely self-consistent.
        assert_eq!(adler32(b"Wikipedia"), 0x11E6_0398);
    }

    #[test]
    fn crc32_matches_the_reference_value() {
        let mut crc = Crc32::default();
        crc.push(b"123456789");
        assert_eq!(crc.finish(), 0xCBF4_3926);
    }

    /// Twenty thousand bytes, which is more than adler32's 5552-byte chunk: a checksum
    /// that reduced only once, or once too often, agrees with zlib on the short vectors
    /// above and disagrees here. Both values come from Python's `zlib`, and the input is
    /// split across two `push` calls so the CRC's carried state is pinned too.
    #[test]
    fn the_checksums_agree_with_zlib_past_one_chunk() {
        let data: Vec<u8> = (0..20_000u32).map(|i| (i * 37 + 11) as u8).collect();
        assert_eq!(adler32(&data), 0xDCA8_EA4B);
        let mut crc = Crc32::default();
        crc.push(&data[..7_000]);
        crc.push(&data[7_000..]);
        assert_eq!(crc.finish(), 0x897E_9E86);
    }
}
