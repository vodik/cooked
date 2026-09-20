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
//! the text *is* the strong reference and Emacs' own collector owns it. Nothing is asked
//! back, and the one thing said in the other direction is `cooked--image-forget' — Emacs
//! reporting that it has dropped a picture, so that this side stops claiming it has been
//! sent. See [`ImageStore`], which is the whole of the bookkeeping that report keeps
//! honest.
//!
//! **Identity is the content.** An [`ImageId`] is minted per distinct byte string, not
//! per transmission, so a program redrawing the same picture every frame — which is what
//! an image viewer or a plotting TUI does — costs one decode in Emacs no matter how many
//! times it arrives. It also means a client that reuses its own ids for different images
//! cannot make two pictures share a key.

use std::collections::HashMap;
use std::num::NonZeroU16;

use super::content_hash;
use super::intern::{Ledger, dense_id};

dense_id! {
    /// The wire name for one distinct image.
    ///
    /// A dense index rather than the content hash itself, so a placement costs four bytes
    /// per cell. The hash decides *which* index — see [`ImageStore::intern`] — which is what
    /// makes the identity content-addressed while keeping the name narrow.
    pub struct ImageId;
}

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

/// Which [`ImageFormat`]s Emacs can show for a session, as the child's answers see them.
///
/// Empty when nothing can be shown -- images are off, or every window on the buffer is on
/// a terminal frame -- and otherwise the formats the Emacs build decodes. The answers ask
/// by format because they are about different ones: sixel arrives here as a PNG, so DA1's
/// `4` needs PNG, while a kitty `f=24` probe becomes binary P6 and needs only `pbm`, which
/// every Emacs with images has. A build without libpng can show the second and not the
/// first.
///
/// `Default` shows everything, which is what a bare emulator implements. A session starts
/// from [`ShownFormats::NONE`] instead, until Emacs says otherwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShownFormats(u8);

impl ShownFormats {
    /// Nothing can be shown.
    pub const NONE: Self = Self(0);
    /// Every format Emacs is ever handed.
    pub const ALL: Self = Self(
        Self::bit(ImageFormat::Png)
            | Self::bit(ImageFormat::Jpeg)
            | Self::bit(ImageFormat::Gif)
            | Self::bit(ImageFormat::Ppm),
    );

    const fn bit(format: ImageFormat) -> u8 {
        1 << format as u8
    }

    /// Whether a picture in FORMAT would be shown.
    pub fn shows(self, format: ImageFormat) -> bool {
        self.0 & Self::bit(format) != 0
    }

    /// Whether any picture at all would be shown.
    pub fn any(self) -> bool {
        self != Self::NONE
    }
}

impl Default for ShownFormats {
    fn default() -> Self {
        Self::ALL
    }
}

impl FromIterator<ImageFormat> for ShownFormats {
    /// The set holding exactly the formats iterated.
    fn from_iter<I: IntoIterator<Item = ImageFormat>>(formats: I) -> Self {
        Self(formats.into_iter().fold(0, |bits, f| bits | Self::bit(f)))
    }
}

/// A size in pixels.
///
/// A named pair rather than `(u32, u32)`, because `.0`/`.1` at a call site says nothing
/// about which axis it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct PixelSize {
    pub w: u32,
    pub h: u32,
}

impl PixelSize {
    pub fn new(w: u32, h: u32) -> Self {
        Self { w, h }
    }

    /// Whether either axis is zero, which makes the whole thing undrawable. The sniffers,
    /// the kitty validator and the sixel decoder all ask this.
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
/// with `text-scale-mode` as well as with the font. Both axes are nonzero by
/// construction. A terminal frame has no cell size at all, and that is spelled
/// `Option::<CellMetrics>::None` wherever it can arise, so every reader has to decide what
/// an unreported size means rather than dividing by a zero it forgot to check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellMetrics {
    width: NonZeroU16,
    height: NonZeroU16,
}

impl CellMetrics {
    /// A cell WIDTH by HEIGHT pixels, or `None` if either is zero -- which is what an
    /// unreported size arrives as on both of the wires it crosses.
    pub const fn new(width: u16, height: u16) -> Option<Self> {
        match (NonZeroU16::new(width), NonZeroU16::new(height)) {
            (Some(width), Some(height)) => Some(Self { width, height }),
            _ => None,
        }
    }

    pub const fn width(self) -> u16 {
        self.width.get()
    }

    pub const fn height(self) -> u16 {
        self.height.get()
    }

    /// How many pixels ROWS by COLS of these cells cover.
    ///
    /// The one place that product is taken, for every report that states it: `14t`,
    /// XTSMGRAPHICS, the mode 2048 report and `TIOCSWINSZ`. The reports disagree about
    /// which axis comes first, and a named pair is what stops one being read off another.
    pub fn text_area(self, rows: usize, cols: usize) -> PixelSize {
        let axis = |cells: usize, cell: NonZeroU16| {
            u32::try_from(cells)
                .unwrap_or(u32::MAX)
                .saturating_mul(u32::from(cell.get()))
        };
        PixelSize::new(axis(cols, self.width), axis(rows, self.height))
    }
}

impl PixelSize {
    /// How many cells across and down a picture of this size covers in cells of METRICS.
    ///
    /// Rounded up, because a picture that does not divide evenly into cells still has to
    /// own the cell it spills into. Without metrics each axis is one cell, which keeps a
    /// placement well-formed on a terminal frame even though nothing will draw it.
    pub fn cells(self, metrics: Option<CellMetrics>) -> CellSize {
        let Some(metrics) = metrics else {
            return CellSize::new(1, 1);
        };
        let axis = |size: u32, cell: NonZeroU16| -> u16 {
            u16::try_from(size.div_ceil(u32::from(cell.get())).max(1)).unwrap_or(u16::MAX)
        };
        CellSize::new(axis(self.w, metrics.width), axis(self.h, metrics.height))
    }
}

/// Which cell of which image a column is showing, and at what size.
///
/// Per cell rather than one record for the whole rectangle, because the rectangle does
/// not survive contact with the grid: text overwrites part of it, a scroll splits it
/// across the screen/scrollback seam, a rewrap moves its rows relative to each other.
/// Addressing each cell separately means all of that is handled by the machinery that
/// already handles it for characters, and none of it needs a case here.
///
/// `cols`/`rows` are the rectangle *this* placement was laid at, repeated on every cell.
/// It belongs to the placement rather than the image, because one picture can be on screen
/// at two sizes: `viu` on a window reshape retransmits the same bytes with a new
/// `c=`/`r=`, and content addressing gives both placements one id. Held here, each cell
/// says how to cut itself, and a row in scrollback keeps the answer it was written with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub id: ImageId,
    pub cell_row: u16,
    pub cell_col: u16,
    /// The rectangle this placement was laid at, which is what Emacs sizes the spec to.
    pub cols: u16,
    pub rows: u16,
}

/// Everything the module keeps about an image once its bytes have gone to Lisp.
///
/// Neither field is a cached measurement: `px` is what the picture *is*, `asked` is what
/// the child *said*, and the cell rectangle is worked out from the two when needed. See
/// [`ImageStore::cells`] for why it cannot be computed once and kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Image {
    /// Intrinsic pixel size, which is what a placement naming no rectangle is measured
    /// from -- against the cell of the moment, not the cell at transmission.
    pub px: PixelSize,
    /// The rectangle the child asked for with `c=`/`r=`, if it asked at all.
    pub asked: Option<CellSize>,
}

/// One image's bytes on their way to Lisp, exactly once.
///
/// No cell rectangle: the bytes cross once and the picture can then be laid at any size,
/// so the rectangle rides every [`Placement`] instead.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageData {
    pub id: ImageId,
    pub format: ImageFormat,
    pub bytes: Vec<u8>,
    pub px: PixelSize,
}

/// Distinct images this store will name at once.
///
/// An entry is a geometry, a digest and two links, some forty bytes. The cap is so that a
/// session running for a week does not grow a map forever, not to bound anything a user
/// would notice.
pub(crate) const MAX_TRACKED_IMAGES: usize = 4096;

/// The images this terminal knows about.
///
/// **One cache, and it is Emacs'.** The bytes are not here: they cross to Lisp once and
/// live in `cooked--image-data', which is the only copy. What this keeps is bookkeeping
/// -- what each id's content was, and how big -- and its single invariant is that the
/// bookkeeping agrees with what Lisp holds: *an id is tracked here if and only if the
/// module believes Lisp still has its bytes.*
///
/// The module cannot work that out for itself, so Lisp says: every path in cooked-deco.el
/// that drops an image calls `cooked--image-forget', which reaches [`Self::forget`]. If the
/// two sides kept separate eviction policies, [`Self::intern`] would answer "you already
/// have this one" about frames Emacs had evicted, and an animation would draw nothing for
/// part of every loop.
#[derive(Debug, Default)]
pub(crate) struct ImageStore {
    /// Ids, hash buckets and LRU order; see [`Ledger`].
    ledger: Ledger<ImageId>,
    images: HashMap<ImageId, Image>,
    /// What each id's bytes hashed to, which is all that is kept of them.
    ///
    /// The ledger buckets by the low half; the whole 128 bits is what settles whether a
    /// transmission is the same picture as one already named. See
    /// [`content_hash`] for why a digest is allowed to be the last
    /// word here where a hyperlink's URI is not.
    hashes: HashMap<ImageId, u128>,
}

/// What [`ImageStore::intern`] decided about one transmission.
///
/// A struct because of `retired`: the count cap can drop an id while naming a new one, and
/// what the rest of the emulator hangs off an id -- the client-id map in
/// [`Kitty`](super::kitty::Kitty) -- has to go at the same moment. Returning it makes that
/// the caller's visible obligation.
#[derive(Debug)]
pub(crate) struct Interned {
    pub id: ImageId,
    /// Whether Lisp has yet to see these bytes, and so whether they must cross.
    pub fresh: bool,
    /// Ids the count cap dropped to make room for this one, usually none.
    pub retired: Vec<ImageId>,
}

impl ImageStore {
    /// Take BYTES as an image, returning its id and whether Lisp has yet to see it.
    ///
    /// The same bytes always come back with the same id and `fresh` false, which is the
    /// whole point of hashing the content: a child redrawing one picture per frame
    /// transmits it per frame, and only the first of those needs to cross the boundary.
    ///
    /// "The same bytes" is decided by the 128-bit digest alone. Keeping payloads to compare
    /// would make this a second cache of every frame with an eviction policy of its own,
    /// able to disagree with Lisp's; with the digest as the entry there is nothing to shed.
    pub(crate) fn intern(&mut self, bytes: &[u8], px: PixelSize) -> Interned {
        let hash = content_hash(bytes);
        // The ledger's buckets are 64 bits wide; the full digest is what a hit is
        // confirmed against, so a shared bucket still gives two pictures two ids.
        let bucket = hash as u64;
        if let Some(id) = self
            .ledger
            .find(bucket, |id| self.hashes.get(&id) == Some(&hash))
        {
            return Interned {
                id,
                fresh: false,
                retired: Vec::new(),
            };
        }

        let id = self.ledger.insert(bucket);
        self.images.insert(id, Image { px, asked: None });
        self.hashes.insert(id, hash);
        Interned {
            id,
            fresh: true,
            retired: self.evict(),
        }
    }

    /// How big to lay this picture, given the cell METRICS of the moment.
    ///
    /// The answer to a bare `a=p`, which names an id and no geometry at all, and nothing
    /// else: what a picture already on the grid is showing rides its [`Placement`].
    ///
    /// Two cases, which is why this is not one stored rectangle. A child that said
    /// `c=`/`r=` was talking about the screen and means the same whatever the font, so its
    /// answer is replayed verbatim. A child that said nothing was talking about its pixels,
    /// whose cell count changes with the font, so it is measured again here; a stored
    /// measurement would make a gif alternate between two sizes across a zoom.
    ///
    /// `None` for an id the store has forgotten.
    pub(crate) fn cells(&self, id: ImageId, metrics: Option<CellMetrics>) -> Option<CellSize> {
        let image = self.images.get(&id)?;
        Some(image.asked.unwrap_or_else(|| image.px.cells(metrics)))
    }

    /// Record whether the child named a rectangle for this picture, and which.
    ///
    /// `None` puts it back to being measured from its pixels. Overwritten on every
    /// transmission rather than fixed at the first, because it exists to answer a later
    /// bare `a=p` and the most recent thing the child said is the best answer to that.
    /// Kept in the same entry as the id so that it goes when the image does.
    pub(crate) fn set_asked(&mut self, id: ImageId, asked: Option<CellSize>) {
        if let Some(image) = self.images.get_mut(&id) {
            image.asked = asked;
        }
    }

    /// Emacs has dropped this image's bytes, so stop claiming it has them.
    ///
    /// The other half of the invariant on [`ImageStore`], and the reason there is a
    /// `cooked--image-forget' at all: the next transmission of these bytes now mints a
    /// fresh id and crosses the boundary, instead of being answered with the name of a
    /// picture nothing can draw any more.
    ///
    /// The caller retires the id's client name too; see [`Interned::retired`] for why
    /// that cannot be left to a comment.
    pub(crate) fn forget(&mut self, id: ImageId) {
        self.ledger.remove(id);
        self.images.remove(&id);
        self.hashes.remove(&id);
    }

    /// Drop the oldest entries once there are more than the count cap allows, returning
    /// what went.
    fn evict(&mut self) -> Vec<ImageId> {
        let mut retired = Vec::new();
        while self.ledger.len() > MAX_TRACKED_IMAGES {
            let Some(id) = self.ledger.evict_oldest() else {
                break;
            };
            self.images.remove(&id);
            self.hashes.remove(&id);
            retired.push(id);
        }
        retired
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const METRICS: Option<CellMetrics> = CellMetrics::new(10, 20);

    /// Frame N of an animation: three megabytes, as a raw RGBA frame of a picture worth
    /// looking at is, and distinct from every other N.
    fn frame(n: u8) -> Vec<u8> {
        let mut bytes = vec![0u8; 3 << 20];
        bytes[0] = n;
        bytes
    }

    #[test]
    fn the_same_bytes_intern_to_the_same_id_once() {
        let mut store = ImageStore::default();
        let a = store.intern(b"pixels", PixelSize::new(10, 20));
        let b = store.intern(b"pixels", PixelSize::new(10, 20));
        assert_eq!(a.id, b.id);
        assert!(a.fresh, "the first transmission has to reach Lisp");
        assert!(!b.fresh, "the second must not");
    }

    #[test]
    fn different_bytes_get_different_ids() {
        let mut store = ImageStore::default();
        let a = store.intern(b"one", PixelSize::new(10, 20));
        let b = store.intern(b"two", PixelSize::new(10, 20));
        assert_ne!(a.id, b.id);
    }

    #[test]
    fn cell_coverage_rounds_up() {
        // A picture that does not divide evenly still owns the cell it spills into.
        assert_eq!(PixelSize::new(10, 20).cells(METRICS), CellSize::new(1, 1));
        assert_eq!(PixelSize::new(11, 21).cells(METRICS), CellSize::new(2, 2));
        assert_eq!(
            PixelSize::new(100, 200).cells(METRICS),
            CellSize::new(10, 10)
        );
    }

    #[test]
    fn unreported_metrics_still_give_a_well_formed_placement() {
        // A terminal frame never reports a cell size; nothing will draw the image, but
        // the geometry must not come out zero-sized and put placements nowhere.
        assert_eq!(PixelSize::new(640, 480).cells(None), CellSize::new(1, 1));
    }

    #[test]
    fn a_zero_sized_image_still_covers_one_cell() {
        assert_eq!(PixelSize::new(0, 0).cells(METRICS), CellSize::new(1, 1));
    }

    #[test]
    fn geometry_is_remembered_after_the_bytes_are_handed_over() {
        let mut store = ImageStore::default();
        let id = store.intern(b"pixels", PixelSize::new(25, 40)).id;
        assert_eq!(store.cells(id, METRICS), Some(CellSize::new(3, 2)));
    }

    /// A real hash collision is expensive to find by brute force in a unit test, so this
    /// plants one directly: a decoy id occupies the bucket a real payload would file
    /// under, with a different digest behind it. The bucket is 64 bits wide and the
    /// digest is 128, so sharing a bucket is not sharing an identity -- and if it ever
    /// became one, the decoy's id and its already-cached display in Lisp would come back
    /// for genuinely different pixels.
    #[test]
    fn a_shared_hash_bucket_does_not_alias_different_bytes() {
        let mut store = ImageStore::default();
        let decoy = ImageId::from_index(999);
        store.images.insert(
            decoy,
            Image {
                px: PixelSize::new(1, 1),
                asked: None,
            },
        );
        store.hashes.insert(decoy, content_hash(b"decoy"));
        store
            .ledger
            .plant(content_hash(b"real pixels") as u64, decoy);

        let real = store.intern(b"real pixels", PixelSize::new(10, 20));
        assert!(
            real.fresh,
            "a same-bucket decoy with a different digest is not a match"
        );
        assert_ne!(real.id, decoy);
        assert_eq!(store.hashes[&decoy], content_hash(b"decoy"), "untouched");
    }

    /// Thirty distinct multi-megabyte frames, then the first one again byte for byte. The
    /// answer is "not fresh", and it is *true*: the store keeps no payloads to shed, so its
    /// claim that Lisp has the picture holds until Lisp says otherwise. Ninety megabytes of
    /// frames leave ninety digests behind.
    #[test]
    fn a_frame_the_store_still_names_does_not_cross_twice() {
        let mut store = ImageStore::default();
        let first = store.intern(&frame(0), PixelSize::new(10, 20));
        for n in 1..30u8 {
            store.intern(&frame(n), PixelSize::new(10, 20));
        }
        let again = store.intern(&frame(0), PixelSize::new(10, 20));
        assert_eq!(again.id, first.id);
        assert!(!again.fresh, "nothing shed it, so Lisp still has it");
    }

    /// The other half of the same invariant, and the one that makes the animation draw:
    /// once Emacs says it has dropped the bytes, the next transmission of them is a new
    /// picture -- a fresh id, and a payload that crosses.
    #[test]
    fn a_forgotten_frame_crosses_again() {
        let mut store = ImageStore::default();
        let first = store.intern(&frame(0), PixelSize::new(10, 20));
        store.forget(first.id);
        assert_eq!(
            store.cells(first.id, METRICS),
            None,
            "and its geometry goes with it"
        );

        let again = store.intern(&frame(0), PixelSize::new(10, 20));
        assert!(again.fresh, "the bytes have to cross again");
        assert_ne!(again.id, first.id, "a forgotten id is not reissued");
    }

    /// Geometry and digest are one entry, so nothing survives the id that named it -- in
    /// particular not the rectangle `a=p` re-placement reads.
    #[test]
    fn nothing_outlives_the_entry_it_belongs_to() {
        let mut store = ImageStore::default();
        let id = store.intern(b"pixels", PixelSize::new(10, 20)).id;
        store.set_asked(id, Some(CellSize::new(4, 3)));
        assert_eq!(store.cells(id, METRICS), Some(CellSize::new(4, 3)));

        store.forget(id);
        assert_eq!(store.cells(id, METRICS), None);
        assert!(store.hashes.is_empty() && store.images.is_empty());
        assert_eq!(store.ledger.len(), 0);
        assert_eq!(store.ledger.tracked(), 0, "no bucket is left stranded");
    }

    #[test]
    fn the_count_cap_retires_the_oldest_and_says_which() {
        let mut store = ImageStore::default();
        let mut ids = Vec::new();
        for n in 0..MAX_TRACKED_IMAGES {
            ids.push(store.intern(&n.to_le_bytes(), PixelSize::new(10, 20)));
        }
        assert!(
            ids.iter().all(|interned| interned.retired.is_empty()),
            "nothing is retired below the cap"
        );

        let over = store.intern(b"one too many", PixelSize::new(10, 20));
        // Named rather than merely dropped: the caller has to retire the client's own
        // name for the picture at the same moment. See `Interned::retired`.
        assert_eq!(over.retired, vec![ids[0].id]);
        assert_eq!(store.cells(ids[0].id, METRICS), None);
        assert_eq!(store.ledger.len(), MAX_TRACKED_IMAGES);
    }
}
