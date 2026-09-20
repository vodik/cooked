//! Renditions as small integers: the table a cell's [`StyleId`] names.
//!
//! A cell holds an id rather than its colours, for two reasons that come to the same
//! thing. The id is four bytes however much a rendition carries, so the underline's own
//! colour (`SGR 58`) fits in a cell beside the foreground and background instead of in a
//! side table walked per column. And a rendition is resolved into an Emacs face once per
//! id rather than once per span: the table crosses to Lisp one new entry at a time, as
//! the drain's `:styles`, and Lisp keeps a vector of faces indexed by id.
//!
//! Id 0 is the default rendition, always, which makes a blank cell in the default pen a
//! zero field and lets "is this the default style" be a comparison against a constant.
//!
//! The table is bounded, because a child chooses how many renditions it uses: a stream
//! of distinct truecolour pens mints one id per character. When it fills, the ids no
//! longer referenced from anything that holds them -- the grids, Emacs' copy of the
//! screen, rows waiting to be drained -- are freed for reuse. A freed id is announced
//! again when it is reused, before any row naming it reaches Lisp, and text already in
//! the buffer holds its face as a value rather than an id, so reuse can never recolour
//! anything.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

use super::cell::{Attrs, Color, STYLE_MAX, Style};

/// The name of one rendition in a [`StyleStore`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct StyleId(u32);

impl StyleId {
    /// The default rendition, which every store holds at this id and never frees.
    pub const DEFAULT: Self = Self(0);

    /// The id as it crosses to Lisp.
    pub const fn get(self) -> u32 {
        self.0
    }

    /// Whether this is the default rendition.
    pub const fn is_default(self) -> bool {
        self.0 == 0
    }

    /// The id a wire value or a test names. The store is what gives it a meaning.
    pub const fn from_raw(value: u32) -> Self {
        Self(value)
    }
}

/// How many renditions a store holds before it looks for ids to free.
///
/// Far past what a screen of ordinary output uses -- a coloured shell and a TUI need a
/// few dozen -- and small enough that a child minting a rendition per character reaches
/// it quickly and is cleaned up after rather than growing the table without limit.
///
/// [`StyleStore::collect`] doubles [`StyleStore::limit`] past this constant when a
/// collection frees too little, and the true ceiling that ratchet can reach is what a
/// rendition-per-cell flood can actually keep live: the cells of both the primary and
/// the alternate grid, the front buffer's copy of what is shown, and the runs of
/// whatever scrollback is still undrained. For R rows and C columns with N undrained
/// scrollback rows -- one run per cell in the worst case, a run never joining its
/// neighbour -- that is at most `C * (3 * R + N)`, and since `limit` only grows when a
/// collection finds everything it marked still live, it cannot ratchet past twice that
/// before the marks themselves stop growing. At the session's default undrained-row
/// ceiling (`BACKLOG_HIGH_WATER`, 8,000 in `term/mod.rs`) and a generous 200x400 grid --
/// the same one [`super::cell::Cell`]'s own field widths are sized against -- that comes
/// to `400 * (600 + 8_000) = 3,440,000`, comfortably under the rendition field's
/// 4,194,303 (`STYLE_MAX`, 22 bits). A caller can raise the backlog past that default,
/// though, so `collect` also clamps `limit` at [`STYLE_MAX`] rather than trusting every
/// caller's configuration to stay inside the margin; see
/// `a_truecolour_flood_keeps_the_table_within_its_bound` in `term::tests::collect` for
/// the same shape pinned at a size that stays fast to test.
pub(crate) const STYLE_TABLE_CAPACITY: usize = 4096;

/// Renditions by id, and ids by rendition; see the module comment.
#[derive(Debug)]
pub(crate) struct StyleStore {
    /// Every slot, by id. A freed slot keeps its old rendition until it is reused, and is
    /// found through `free` rather than by what it holds.
    styles: Vec<Style>,
    ids: HashMap<StyleKey, StyleId, BuildHasherDefault<StyleHasher>>,
    /// Slots available for reuse, most recently freed last.
    free: Vec<StyleId>,
    /// The last two renditions looked up, which covers a writer alternating between its
    /// pen and the blank an erase leaves, so the hash map is consulted only when the pen
    /// actually changes.
    recent: [(StyleKey, StyleId); 2],
    /// For each slot, the bits of its rendition that change the font: bold, faint and
    /// italic. See [`StyleStore::font_bits`].
    fonts: Vec<u8>,
    /// Ids defined or redefined since Lisp was last told, in the order they were made.
    unsent: Vec<StyleId>,
    /// How many live renditions trigger a collection. Starts at
    /// [`STYLE_TABLE_CAPACITY`] and grows when a collection frees too little, so a screen
    /// that genuinely shows more renditions than the cap does not collect on every write.
    limit: usize,
}

impl Default for StyleStore {
    fn default() -> Self {
        let mut ids = HashMap::default();
        ids.insert(StyleKey::of(Style::default()), StyleId::DEFAULT);
        Self {
            styles: vec![Style::default()],
            fonts: vec![0],
            ids,
            free: Vec::new(),
            recent: [(StyleKey::DEFAULT, StyleId::DEFAULT); 2],
            unsent: Vec::new(),
            limit: STYLE_TABLE_CAPACITY,
        }
    }
}

impl StyleStore {
    /// A store that looks for ids to free once LIMIT renditions are live, rather than at
    /// [`STYLE_TABLE_CAPACITY`].
    ///
    /// For a test that wants collections to happen every few writes instead of once in
    /// four thousand renditions: a limit of 4 puts an id's reuse within reach of a script
    /// a few steps long. The limit still grows as [`StyleStore::collect`] describes.
    pub(crate) fn with_limit(limit: usize) -> Self {
        Self {
            limit,
            ..Self::default()
        }
    }

    /// The id STYLE already has, if it has one.
    pub(crate) fn lookup(&mut self, style: Style) -> Option<StyleId> {
        let key = StyleKey::of(style);
        if self.recent[0].0 == key {
            return Some(self.recent[0].1);
        }
        if self.recent[1].0 == key {
            self.recent.swap(0, 1);
            return Some(self.recent[0].1);
        }
        let id = *self.ids.get(&key)?;
        self.recent = [(key, id), self.recent[0]];
        Some(id)
    }

    /// Whether giving another rendition an id should wait for a collection first.
    pub(crate) fn is_full(&self) -> bool {
        self.ids.len() >= self.limit
    }

    /// Give STYLE an id, which the caller has checked it does not have.
    pub(crate) fn insert(&mut self, style: Style) -> StyleId {
        let id = match self.free.pop() {
            Some(id) => {
                self.styles[id.0 as usize] = style;
                self.fonts[id.0 as usize] = font_bits(style);
                id
            }
            None => {
                let id = StyleId(self.styles.len() as u32);
                self.styles.push(style);
                self.fonts.push(font_bits(style));
                id
            }
        };
        let key = StyleKey::of(style);
        self.ids.insert(key, id);
        self.unsent.push(id);
        self.recent = [(key, id), self.recent[0]];
        id
    }

    /// The rendition ID names. An id this store never handed out reads as the default.
    pub(crate) fn get(&self, id: StyleId) -> Style {
        self.styles.get(id.0 as usize).copied().unwrap_or_default()
    }

    /// Which of each id's renditions change the font, indexed by id: bold is 1, faint 2 and
    /// italic 4, the attributes `cooked--ascii-fixed-pitch-p' probes a font for.
    ///
    /// What a row's layout hash needs of a rendition, handed over with the drain so the
    /// hash can be taken where the rows are encoded, without the store.
    pub(crate) fn font_bits(&self) -> &[u8] {
        &self.fonts
    }

    /// How many ids are live.
    pub(crate) fn len(&self) -> usize {
        self.ids.len()
    }

    /// Free every id MARK does not report, keeping the default.
    ///
    /// MARK is handed a function to call with each id still referenced, and must report
    /// every place an id can be held until the next collection: an id it misses may be
    /// reused for another rendition while a cell still names it.
    pub(crate) fn collect(&mut self, mark: impl FnOnce(&mut dyn FnMut(StyleId))) {
        let mut live = vec![false; self.styles.len()];
        live[0] = true;
        mark(&mut |id: StyleId| {
            if let Some(slot) = live.get_mut(id.0 as usize) {
                *slot = true;
            }
        });
        let styles = &self.styles;
        self.ids.retain(|_, id| live[id.0 as usize]);
        self.free.clear();
        self.free.extend(
            (1..styles.len())
                .rev()
                .map(|index| StyleId(index as u32))
                .filter(|id| !live[id.0 as usize]),
        );
        // A freed id that was never announced does not need to be: nothing names it.
        self.unsent.retain(|id| live[id.0 as usize]);
        self.recent = [(StyleKey::DEFAULT, StyleId::DEFAULT); 2];
        self.limit = grown_limit(self.limit, self.ids.len());
    }

    /// The ids defined since the last call, with their renditions, for the drain to send.
    pub(crate) fn take_unsent(&mut self) -> Vec<(StyleId, Style)> {
        let styles = &self.styles;
        let unsent = std::mem::take(&mut self.unsent);
        unsent
            .into_iter()
            .map(|id| (id, styles[id.0 as usize]))
            .collect()
    }
}

/// A rendition packed into two machine words, which is what the store compares and hashes.
///
/// [`Style`]'s derived comparison walks three [`Color`] enums tag by tag, and the store
/// compares a rendition against its recent entries on every change of pen: a log that
/// alternates `SGR 31` and `SGR 0` on every line does it twice a line. Packed, the same
/// question is two integer compares, and the hash is two mixes instead of a walk.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct StyleKey(u64, u64);

impl StyleKey {
    const DEFAULT: Self = Self(0, 0);

    /// Each colour is a tag in its top byte (0 default, 1 indexed, 2 direct) and its value
    /// below, so the default rendition packs to zero and no two renditions share a key.
    fn of(style: Style) -> Self {
        const fn color(c: Color) -> u64 {
            match c {
                Color::Default => 0,
                Color::Indexed(i) => (1 << 24) | i as u64,
                Color::Rgb(r, g, b) => (2 << 24) | (r as u64) << 16 | (g as u64) << 8 | b as u64,
            }
        }
        Self(
            color(style.fg) << 32 | color(style.bg),
            color(style.underline) << 32 | u64::from(style.attrs.bits()),
        )
    }
}

/// A hasher for the rendition map, which is asked on every change of pen.
///
/// The default hasher is SipHash, built to resist a child searching for collisions, and
/// a collision here costs a bucket a longer scan and nothing else: every hit is compared
/// in full. So this is the same rotate-xor-multiply [`super::mix`] the content stores
/// use, which a styled log that changes pen several times a line measured as worth a
/// fifth of its throughput.
#[derive(Default)]
pub(crate) struct StyleHasher(u64);

impl Hasher for StyleHasher {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for chunk in bytes.chunks(8) {
            let mut word = [0u8; 8];
            word[..chunk.len()].copy_from_slice(chunk);
            self.0 = super::mix(self.0, u64::from_le_bytes(word));
        }
    }

    fn write_u8(&mut self, value: u8) {
        self.0 = super::mix(self.0, u64::from(value));
    }

    fn write_u16(&mut self, value: u16) {
        self.0 = super::mix(self.0, u64::from(value));
    }

    fn write_u32(&mut self, value: u32) {
        self.0 = super::mix(self.0, u64::from(value));
    }

    fn write_u64(&mut self, value: u64) {
        self.0 = super::mix(self.0, value);
    }

    fn write_usize(&mut self, value: usize) {
        self.0 = super::mix(self.0, value as u64);
    }

    fn write_isize(&mut self, value: isize) {
        self.0 = super::mix(self.0, value as u64);
    }
}

/// The next [`StyleStore::limit`] after a collection leaves LIVE ids referenced.
///
/// Doubling LIVE makes room for a screen that keeps minting new renditions to do so for
/// a while before it collects again, rather than on every write once it is full -- see
/// [`StyleStore::collect`]. The `min` is the ceiling `STYLE_TABLE_CAPACITY`'s doc works
/// out: past [`STYLE_MAX`], no id this store hands out can reach a cell anyway (an id
/// too wide for its field degrades to the default rendition rather than aliasing, see
/// [`super::cell::Cell::linked`]), so growing `limit` any further would only buy fewer,
/// later collections over an id space nothing can use.
fn grown_limit(current: usize, live: usize) -> usize {
    current.max(live * 2).min(STYLE_MAX as usize)
}

/// The bits of STYLE that change the font; see [`StyleStore::font_bits`].
fn font_bits(style: Style) -> u8 {
    let attrs = style.attrs;
    [Attrs::BOLD, Attrs::FAINT, Attrs::ITALIC]
        .iter()
        .enumerate()
        .filter(|(_, flag)| attrs.contains(**flag))
        .fold(0, |bits, (bit, _)| bits | 1 << bit)
}

#[cfg(test)]
mod tests {
    use super::super::cell::Color;
    use super::*;

    fn red(n: u8) -> Style {
        Style {
            fg: Color::Rgb(n, 0, 0),
            ..Style::default()
        }
    }

    #[test]
    fn the_default_rendition_is_id_zero_and_is_never_announced() {
        let mut store = StyleStore::default();
        assert_eq!(store.lookup(Style::default()), Some(StyleId::DEFAULT));
        assert!(store.take_unsent().is_empty());
    }

    #[test]
    fn a_rendition_keeps_its_id_and_is_announced_once() {
        let mut store = StyleStore::default();
        let id = store.insert(red(1));
        assert_eq!(store.lookup(red(1)), Some(id));
        assert_eq!(store.take_unsent(), vec![(id, red(1))]);
        assert!(store.take_unsent().is_empty());
        assert_eq!(store.get(id), red(1));
    }

    #[test]
    fn a_collection_frees_what_is_unreferenced_and_a_reused_id_is_announced_again() {
        let mut store = StyleStore::default();
        let kept = store.insert(red(1));
        let dropped = store.insert(red(2));
        store.take_unsent();
        store.collect(|mark| mark(kept));
        assert_eq!(store.lookup(red(1)), Some(kept));
        assert_eq!(store.lookup(red(2)), None);
        let reused = store.insert(red(3));
        assert_eq!(reused, dropped, "the freed slot is reused");
        assert_eq!(store.take_unsent(), vec![(reused, red(3))]);
        assert_eq!(store.get(reused), red(3));
    }

    #[test]
    fn a_collection_that_frees_little_raises_the_limit() {
        let mut store = StyleStore::default();
        let ids: Vec<_> = (0..STYLE_TABLE_CAPACITY)
            .map(|n| store.insert(red((n % 251) as u8).with_attrs_bits(n as u16)))
            .collect();
        assert!(store.is_full());
        store.collect(|mark| ids.iter().for_each(|&id| mark(id)));
        assert!(
            !store.is_full(),
            "everything is live, so the limit has to move"
        );
    }

    #[test]
    fn growth_never_prescribes_a_limit_past_what_a_cell_can_hold() {
        assert_eq!(grown_limit(10, 5), 10, "a small live count is a no-op");
        assert_eq!(
            grown_limit(10, 100),
            200,
            "otherwise it doubles the live count"
        );
        assert_eq!(
            grown_limit(10, STYLE_MAX as usize),
            STYLE_MAX as usize,
            "clamped at what the rendition field can hold, not doubled past it"
        );
    }

    impl Style {
        fn with_attrs_bits(self, bits: u16) -> Self {
            Self {
                attrs: Attrs::from_bits(bits),
                ..self
            }
        }
    }
}
