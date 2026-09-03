//! Transmitted images: identity, the store that holds them, and where they sit.
//!
//! The division of labour with Lisp is the one the rest of the crate already uses for
//! box drawing — Rust names a thing per cell, Emacs renders it and caches it — with one
//! difference that decides the whole design: an image's *bytes* cross the boundary
//! exactly once, while its *placements* cross on every redraw of the rows they sit on.
//! Rows are deleted and reinserted wholesale by the renderer, so anything travelling
//! with a row has to be a reference.
//!
//! Two things follow, and neither is an optimisation.
//!
//! **Lifetime is Emacs'.** Scrollback lives in the Emacs buffer, not the grid, so a row
//! carrying a placement can leave the emulator and go on being displayed indefinitely.
//! Rust can therefore never know when the last reference to an image dies. It does not
//! have to: Emacs hangs the image spec on the buffer text as a `display` property, so
//! the text *is* the strong reference and Emacs' own collector owns it. There is no
//! release protocol here because there is nothing for one to do.
//!
//! **Identity is the content.** An [`ImageId`] is minted per distinct byte string, not
//! per transmission, so a program redrawing the same picture every frame — which is what
//! an image viewer or a plotting TUI does — costs one decode in Emacs no matter how many
//! times it arrives. It also means a client that reuses its own ids for different images
//! cannot make two pictures share a key.

use std::collections::HashMap;

use super::fast_hash;
use super::intern::{Id, Ledger};

/// The wire name for one distinct image.
///
/// A dense index rather than the content hash itself, so a placement costs four bytes
/// per cell. The hash decides *which* index — see [`ImageStore::intern`] — which is what
/// makes the identity content-addressed while keeping the name narrow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ImageId(pub u32);

/// What Emacs should hand `create-image` as its type symbol.
///
/// Only formats Emacs decodes natively appear here. Anything the child sends that Emacs
/// cannot read — sixel, kitty's raw pixel transmissions — is converted on the way in
/// rather than given a variant, because a variant Emacs cannot render is a defect that
/// only shows up on somebody else's build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Png,
    Jpeg,
    Gif,
    /// Binary P6, which Emacs decodes with no image library at all. The cheap target for
    /// a sixel or a raw RGB transmission: prepend a header, no encoder. No alpha, so
    /// RGBA still has to become a PNG.
    Ppm,
}

/// A size in pixels.
///
/// A named pair rather than `(u32, u32)` because the tuple form was threaded positionally
/// through four modules, and `.0`/`.1` at a call site says nothing about which axis it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct PixelSize {
    pub w: u32,
    pub h: u32,
}

impl PixelSize {
    pub fn new(w: u32, h: u32) -> Self {
        Self { w, h }
    }

    /// Whether either axis is zero, which makes the whole thing undrawable.
    ///
    /// One predicate replacing three spellings of it: a `(w != 0 && h != 0).then_some(..)`
    /// in the sniffers, a `needed == 0` in the kitty validator, and a bare pair of
    /// comparisons in the sixel decoder.
    pub fn is_empty(self) -> bool {
        self.w == 0 || self.h == 0
    }

    /// Pixel count, in a width wide enough that a hostile size cannot wrap it.
    pub fn area(self) -> u64 {
        u64::from(self.w) * u64::from(self.h)
    }
}

impl From<(u32, u32)> for PixelSize {
    fn from((w, h): (u32, u32)) -> Self {
        Self { w, h }
    }
}

/// A size in cells: how much of the grid something covers.
///
/// Separate from [`PixelSize`] rather than a shared generic pair, because the whole point
/// is that the two cannot be handed to each other by mistake. Named fields rather than a
/// tuple for the same reason: `.0` for columns and `.1` for rows reads backwards at every
/// loop over them, since rows are the outer dimension everywhere else in this crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct CellSize {
    pub cols: u16,
    pub rows: u16,
}

impl CellSize {
    pub fn new(cols: u16, rows: u16) -> Self {
        Self { cols, rows }
    }

    /// What the child actually asked for, if it asked.
    ///
    /// Both wire protocols spell "I did not say" as a zero, and every reader of that had
    /// to know it. `None` here means the pixels decide.
    pub fn asked(self) -> Option<Self> {
        (self != Self::default()).then_some(self)
    }
}

/// The size of one cell in pixels, as Emacs measures it.
///
/// Emacs' to know and ours to answer with: it is the frame's font metrics, and it moves
/// with `text-scale-mode` as well as with the font. Zero means "not reported", which is
/// what a terminal frame stays at, and what every caller here has to tolerate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CellMetrics {
    pub width: u16,
    pub height: u16,
}

impl CellMetrics {
    /// How many cells across and down an image of `px` pixels covers.
    ///
    /// Rounded up, because a picture that does not divide evenly into cells still has to
    /// own the cell it spills into — the alternative is a strip of the image with no cell
    /// to hang it on. Falls back to one cell per axis when the metrics are unreported,
    /// which keeps a placement well-formed on a terminal frame even though nothing will
    /// draw it.
    pub fn cells_for(self, px: PixelSize) -> CellSize {
        let axis = |size: u32, cell: u16| -> u16 {
            if cell == 0 {
                return 1;
            }
            u16::try_from(size.div_ceil(u32::from(cell)).max(1)).unwrap_or(u16::MAX)
        };
        CellSize::new(axis(px.w, self.width), axis(px.h, self.height))
    }

    /// Whether Emacs has told us the font metrics yet; see the note on the struct.
    pub fn is_reported(self) -> bool {
        self.width != 0 && self.height != 0
    }
}

/// Which cell of which image a column is showing.
///
/// Per cell rather than one record for the whole rectangle, because the rectangle does
/// not survive contact with the grid: text overwrites part of it, a scroll splits it
/// across the screen/scrollback seam, a rewrap moves its rows relative to each other.
/// Addressing each cell separately means all of that is handled by the machinery that
/// already handles it for characters, and none of it needs a case here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub id: ImageId,
    pub cell_row: u16,
    pub cell_col: u16,
}

/// Everything retained about an image once its bytes have been handed to Lisp.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Image {
    /// Intrinsic size, which is the aspect ratio Lisp scales slices against.
    pub px: PixelSize,
    /// The cell rectangle it was laid into, fixed at transmission.
    pub cells: CellSize,
}

/// One image's bytes on their way to Lisp, exactly once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageData {
    pub id: ImageId,
    pub format: ImageFormat,
    pub bytes: Vec<u8>,
    pub px: PixelSize,
    pub cells: CellSize,
}

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

/// Total transmitted bytes the store will hold for re-placement before evicting.
///
/// Retained not for lifetime reasons — Emacs owns that — but because kitty's protocol
/// lets a client place an image it transmitted earlier by id alone, and expects that to
/// work. This is the bound on how far back "earlier" reaches.
pub(crate) const MAX_RETAINED_BYTES: usize = 64 << 20;

/// Distinct images whose geometry is remembered, which outlives their bytes.
///
/// Metadata is two words; keeping far more of it than of the payloads costs nothing and
/// means a re-placement usually still knows how big the picture was even after the bytes
/// have gone.
pub(crate) const MAX_TRACKED_IMAGES: usize = 4096;

/// The images this terminal knows about.
#[derive(Debug, Default)]
pub(crate) struct ImageStore {
    /// Ids, hash buckets and LRU order; see [`Ledger`].
    ledger: Ledger<ImageId>,
    images: HashMap<ImageId, Image>,
    /// Transmitted bytes, kept only so an already-transmitted id can be placed again.
    retained: HashMap<ImageId, (ImageFormat, Vec<u8>)>,
    retained_bytes: usize,
}

impl Id for ImageId {
    fn from_index(index: u32) -> Self {
        Self(index)
    }
}

impl ImageStore {
    /// Take BYTES as an image, returning its id and whether Lisp has yet to see it.
    ///
    /// The same bytes always come back with the same id and `false`, which is the whole
    /// point of hashing the content: a child redrawing one picture per frame transmits
    /// it per frame, and only the first of those needs to cross the boundary.
    ///
    /// The hash only narrows the search to a bucket; every candidate whose payload is
    /// still retained is compared byte-for-byte before being treated as the same image
    /// — so two distinct payloads that happen to share a hash get distinct ids rather
    /// than the second silently aliasing the first's already-cached display. The one
    /// case this cannot verify is a candidate whose payload has *already* been evicted
    /// (geometry kept, bytes dropped, see [`Self::evict`]): there is nothing left to
    /// compare against, so a hash hit there is trusted as before. That residual gap
    /// needs a hash collision *and* the true match to have aged out of the byte cap
    /// first, which is narrow enough to accept rather than keep payloads forever to
    /// close it.
    pub(crate) fn intern(
        &mut self,
        format: ImageFormat,
        bytes: &[u8],
        px: PixelSize,
        metrics: CellMetrics,
    ) -> (ImageId, bool) {
        let hash = fast_hash(bytes);
        if let Some(id) = self.ledger.find(hash, |id| {
            self.retained
                .get(&id)
                .is_none_or(|(_, held)| held.as_slice() == bytes)
        }) {
            return (id, false);
        }

        let id = self.ledger.insert(hash);
        self.images.insert(
            id,
            Image {
                px,
                cells: metrics.cells_for(px),
            },
        );
        self.retained_bytes += bytes.len();
        self.retained.insert(id, (format, bytes.to_vec()));
        self.evict();
        (id, true)
    }

    pub(crate) fn get(&self, id: ImageId) -> Option<Image> {
        self.images.get(&id).copied()
    }

    /// The bytes of an already-transmitted image, if they are still held.
    ///
    /// Only the eviction and collision tests read this back: the drain hands the bytes
    /// to Lisp once and thereafter refers to the image by id, so nothing in the crate
    /// asks the store for a payload it has already sent.
    #[cfg(test)]
    pub(crate) fn retained(&self, id: ImageId) -> Option<(ImageFormat, &[u8])> {
        self.retained.get(&id).map(|(f, b)| (*f, b.as_slice()))
    }

    /// Drop payloads over the byte cap, then whole entries over the count cap.
    ///
    /// Payloads go first and separately: losing one costs a re-placement by bare id,
    /// which is rare, while losing the metadata costs the geometry of an image whose
    /// cells may still be on the grid.
    fn evict(&mut self) {
        // Payloads first, oldest first, with the entries left in place.
        let mut over = self.retained_bytes;
        let mut shed = Vec::new();
        for id in self.ledger.lru() {
            if over <= MAX_RETAINED_BYTES {
                break;
            }
            if let Some((_, bytes)) = self.retained.get(&id) {
                over -= bytes.len();
                shed.push(id);
            }
        }
        for id in shed {
            if let Some((_, bytes)) = self.retained.remove(&id) {
                self.retained_bytes -= bytes.len();
            }
        }
        // Then whole entries, once there are more of them than the count cap allows.
        while self.ledger.len() > MAX_TRACKED_IMAGES {
            let Some(id) = self.ledger.evict_oldest() else {
                break;
            };
            self.images.remove(&id);
            if let Some((_, bytes)) = self.retained.remove(&id) {
                self.retained_bytes -= bytes.len();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const METRICS: CellMetrics = CellMetrics {
        width: 10,
        height: 20,
    };

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

    #[test]
    fn the_same_bytes_intern_to_the_same_id_once() {
        let mut store = ImageStore::default();
        let (a, fresh_a) =
            store.intern(ImageFormat::Png, b"pixels", PixelSize::new(10, 20), METRICS);
        let (b, fresh_b) =
            store.intern(ImageFormat::Png, b"pixels", PixelSize::new(10, 20), METRICS);
        assert_eq!(a, b);
        assert!(fresh_a, "the first transmission has to reach Lisp");
        assert!(!fresh_b, "the second must not");
    }

    #[test]
    fn different_bytes_get_different_ids() {
        let mut store = ImageStore::default();
        let (a, _) = store.intern(ImageFormat::Png, b"one", PixelSize::new(10, 20), METRICS);
        let (b, _) = store.intern(ImageFormat::Png, b"two", PixelSize::new(10, 20), METRICS);
        assert_ne!(a, b);
    }

    #[test]
    fn cell_coverage_rounds_up() {
        // A picture that does not divide evenly still owns the cell it spills into.
        assert_eq!(
            METRICS.cells_for(PixelSize::new(10, 20)),
            CellSize::new(1, 1)
        );
        assert_eq!(
            METRICS.cells_for(PixelSize::new(11, 21)),
            CellSize::new(2, 2)
        );
        assert_eq!(
            METRICS.cells_for(PixelSize::new(100, 200)),
            CellSize::new(10, 10)
        );
    }

    #[test]
    fn unreported_metrics_still_give_a_well_formed_placement() {
        // A terminal frame never reports a cell size; nothing will draw the image, but
        // the geometry must not come out zero-sized and put placements nowhere.
        assert_eq!(
            CellMetrics::default().cells_for(PixelSize::new(640, 480)),
            CellSize::new(1, 1)
        );
    }

    #[test]
    fn a_zero_sized_image_still_covers_one_cell() {
        assert_eq!(METRICS.cells_for(PixelSize::new(0, 0)), CellSize::new(1, 1));
    }

    #[test]
    fn geometry_is_remembered_after_the_bytes_are_handed_over() {
        let mut store = ImageStore::default();
        let (id, _) = store.intern(ImageFormat::Png, b"pixels", PixelSize::new(25, 40), METRICS);
        assert_eq!(
            store.get(id),
            Some(Image {
                px: PixelSize::new(25, 40),
                cells: CellSize::new(3, 2)
            })
        );
    }

    /// A real fast-hash collision is expensive to find by brute force in a unit test, so
    /// this plants one directly: a decoy id occupies the bucket a real payload would
    /// hash into, with different retained bytes behind it. Before the fix this was
    /// `intern`'s only check, so the decoy's id (and its already-cached display in
    /// Lisp) would have been returned for genuinely different pixels.
    #[test]
    fn a_shared_hash_bucket_does_not_alias_different_bytes() {
        let mut store = ImageStore::default();
        let decoy = ImageId(999);
        store.images.insert(
            decoy,
            Image {
                px: PixelSize::new(1, 1),
                cells: CellSize::new(1, 1),
            },
        );
        store
            .retained
            .insert(decoy, (ImageFormat::Png, b"decoy".to_vec()));
        let hash = fast_hash(b"real pixels");
        store.ledger.plant(hash, decoy);

        let (id, fresh) = store.intern(
            ImageFormat::Png,
            b"real pixels",
            PixelSize::new(10, 20),
            METRICS,
        );
        assert!(
            fresh,
            "a same-bucket decoy with different bytes is not a match"
        );
        assert_ne!(id, decoy);
        assert_eq!(store.retained(id).unwrap().1, b"real pixels");
        assert_eq!(store.retained(decoy).unwrap().1, b"decoy", "untouched");
    }

    #[test]
    fn payloads_are_dropped_before_geometry_is() {
        let mut store = ImageStore::default();
        let big = vec![0u8; MAX_RETAINED_BYTES / 2 + 1];
        let (first, _) = store.intern(ImageFormat::Png, &big, PixelSize::new(10, 20), METRICS);
        let mut second_big = big.clone();
        second_big[0] = 1;
        let (second, _) = store.intern(
            ImageFormat::Png,
            &second_big,
            PixelSize::new(10, 20),
            METRICS,
        );

        assert!(store.retained(first).is_none(), "oldest payload evicted");
        assert!(store.retained(second).is_some(), "newest payload kept");
        assert!(
            store.get(first).is_some(),
            "geometry outlives the payload, so cells still on the grid stay placeable"
        );
    }
}
