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
use std::hash::{DefaultHasher, Hash, Hasher};

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

impl ImageFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpeg",
            Self::Gif => "gif",
            Self::Ppm => "pbm",
        }
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
    pub fn cells_for(self, px: (u32, u32)) -> (u16, u16) {
        let axis = |size: u32, cell: u16| -> u16 {
            if cell == 0 {
                return 1;
            }
            (size.div_ceil(u32::from(cell)).max(1)).min(u32::from(u16::MAX)) as u16
        };
        (axis(px.0, self.width), axis(px.1, self.height))
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
pub struct Image {
    /// Intrinsic size, which is the aspect ratio Lisp scales slices against.
    pub px: (u32, u32),
    /// The cell rectangle it was laid into, fixed at transmission.
    pub cells: (u16, u16),
}

/// One image's bytes on their way to Lisp, exactly once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageData {
    pub id: ImageId,
    pub format: ImageFormat,
    pub bytes: Vec<u8>,
    pub px: (u32, u32),
    pub cells: (u16, u16),
}

/// Total transmitted bytes the store will hold for re-placement before evicting.
///
/// Retained not for lifetime reasons — Emacs owns that — but because kitty's protocol
/// lets a client place an image it transmitted earlier by id alone, and expects that to
/// work. This is the bound on how far back "earlier" reaches.
pub const MAX_RETAINED_BYTES: usize = 64 << 20;

/// Distinct images whose geometry is remembered, which outlives their bytes.
///
/// Metadata is two words; keeping far more of it than of the payloads costs nothing and
/// means a re-placement usually still knows how big the picture was even after the bytes
/// have gone.
pub const MAX_TRACKED_IMAGES: usize = 4096;

/// The images this terminal knows about.
#[derive(Debug, Default)]
pub struct ImageStore {
    by_hash: HashMap<u64, ImageId>,
    images: HashMap<ImageId, Image>,
    /// Transmitted bytes, kept only so an already-transmitted id can be placed again.
    retained: HashMap<ImageId, (ImageFormat, Vec<u8>)>,
    /// Least-recently-used first, for both caps.
    order: Vec<ImageId>,
    retained_bytes: usize,
    next: u32,
}

impl ImageStore {
    /// Take BYTES as an image, returning its id and whether Lisp has yet to see it.
    ///
    /// The same bytes always come back with the same id and `false`, which is the whole
    /// point of hashing the content: a child redrawing one picture per frame transmits
    /// it per frame, and only the first of those needs to cross the boundary.
    pub fn intern(
        &mut self,
        format: ImageFormat,
        bytes: &[u8],
        px: (u32, u32),
        metrics: CellMetrics,
    ) -> (ImageId, bool) {
        let mut hasher = DefaultHasher::new();
        bytes.hash(&mut hasher);
        let hash = hasher.finish();
        if let Some(&id) = self.by_hash.get(&hash) {
            self.touch(id);
            return (id, false);
        }

        let id = ImageId(self.next);
        self.next = self.next.wrapping_add(1);
        self.by_hash.insert(hash, id);
        self.images.insert(
            id,
            Image {
                px,
                cells: metrics.cells_for(px),
            },
        );
        self.retained_bytes += bytes.len();
        self.retained.insert(id, (format, bytes.to_vec()));
        self.order.push(id);
        self.evict();
        (id, true)
    }

    pub fn get(&self, id: ImageId) -> Option<Image> {
        self.images.get(&id).copied()
    }

    /// The bytes of an already-transmitted image, if they are still held.
    pub fn retained(&self, id: ImageId) -> Option<(ImageFormat, &[u8])> {
        self.retained.get(&id).map(|(f, b)| (*f, b.as_slice()))
    }

    fn touch(&mut self, id: ImageId) {
        if let Some(at) = self.order.iter().position(|&i| i == id) {
            let id = self.order.remove(at);
            self.order.push(id);
        }
    }

    /// Drop payloads over the byte cap, then whole entries over the count cap.
    ///
    /// Payloads go first and separately: losing one costs a re-placement by bare id,
    /// which is rare, while losing the metadata costs the geometry of an image whose
    /// cells may still be on the grid.
    fn evict(&mut self) {
        let mut i = 0;
        while self.retained_bytes > MAX_RETAINED_BYTES && i < self.order.len() {
            let id = self.order[i];
            if let Some((_, bytes)) = self.retained.remove(&id) {
                self.retained_bytes -= bytes.len();
            }
            i += 1;
        }
        while self.order.len() > MAX_TRACKED_IMAGES {
            let id = self.order.remove(0);
            self.images.remove(&id);
            if let Some((_, bytes)) = self.retained.remove(&id) {
                self.retained_bytes -= bytes.len();
            }
            self.by_hash.retain(|_, &mut v| v != id);
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
    fn the_same_bytes_intern_to_the_same_id_once() {
        let mut store = ImageStore::default();
        let (a, fresh_a) = store.intern(ImageFormat::Png, b"pixels", (10, 20), METRICS);
        let (b, fresh_b) = store.intern(ImageFormat::Png, b"pixels", (10, 20), METRICS);
        assert_eq!(a, b);
        assert!(fresh_a, "the first transmission has to reach Lisp");
        assert!(!fresh_b, "the second must not");
    }

    #[test]
    fn different_bytes_get_different_ids() {
        let mut store = ImageStore::default();
        let (a, _) = store.intern(ImageFormat::Png, b"one", (10, 20), METRICS);
        let (b, _) = store.intern(ImageFormat::Png, b"two", (10, 20), METRICS);
        assert_ne!(a, b);
    }

    #[test]
    fn cell_coverage_rounds_up() {
        // A picture that does not divide evenly still owns the cell it spills into.
        assert_eq!(METRICS.cells_for((10, 20)), (1, 1));
        assert_eq!(METRICS.cells_for((11, 21)), (2, 2));
        assert_eq!(METRICS.cells_for((100, 200)), (10, 10));
    }

    #[test]
    fn unreported_metrics_still_give_a_well_formed_placement() {
        // A terminal frame never reports a cell size; nothing will draw the image, but
        // the geometry must not come out zero-sized and put placements nowhere.
        assert_eq!(CellMetrics::default().cells_for((640, 480)), (1, 1));
    }

    #[test]
    fn a_zero_sized_image_still_covers_one_cell() {
        assert_eq!(METRICS.cells_for((0, 0)), (1, 1));
    }

    #[test]
    fn geometry_is_remembered_after_the_bytes_are_handed_over() {
        let mut store = ImageStore::default();
        let (id, _) = store.intern(ImageFormat::Png, b"pixels", (25, 40), METRICS);
        assert_eq!(
            store.get(id),
            Some(Image {
                px: (25, 40),
                cells: (3, 2)
            })
        );
    }

    #[test]
    fn payloads_are_dropped_before_geometry_is() {
        let mut store = ImageStore::default();
        let big = vec![0u8; MAX_RETAINED_BYTES / 2 + 1];
        let (first, _) = store.intern(ImageFormat::Png, &big, (10, 20), METRICS);
        let mut second_big = big.clone();
        second_big[0] = 1;
        let (second, _) = store.intern(ImageFormat::Png, &second_big, (10, 20), METRICS);

        assert!(store.retained(first).is_none(), "oldest payload evicted");
        assert!(store.retained(second).is_some(), "newest payload kept");
        assert!(
            store.get(first).is_some(),
            "geometry outlives the payload, so cells still on the grid stay placeable"
        );
    }
}
