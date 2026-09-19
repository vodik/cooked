//! OSC 8 hyperlinks: identity, and the store that holds their URIs.
//!
//! The same division of labour as [`super::image`], for the same reason and with the
//! same consequences. A hyperlink's *URI* crosses the boundary once; the fact that a
//! given cell is part of that link crosses on every redraw of the row it sits on. So
//! cells carry a [`LinkId`] and nothing else — a URI per cell would put a heap string
//! on the hot path of a feature that is almost never in use — and Emacs holds the
//! table that turns an id back into a destination.
//!
//! **Identity is the content.** An id is minted per distinct URI, not per `OSC 8`
//! sequence, so `ls --hyperlink=auto` in a directory of a thousand files costs a
//! thousand entries, while a build log printing one issue URL on every line of a
//! thousand-line run costs one. That is also what lets the `id=` parameter be ignored
//! outright — see [`LinkStore::intern`].
//!
//! **An id names a transfer, not a destination.** `cooked--render-link-spans' resolves
//! the id as the text is inserted and puts the URI itself on it, so scrollback in the
//! Emacs buffer holds destinations and nothing outside a drain ever asks what an id
//! means. That is what lets an id be freed once no cell names it and handed to the next
//! URI, the way [`StyleStore::collect`](super::style::StyleStore) frees a rendition:
//! see [`LinkStore::collect`], which the caller drives because only it knows what is
//! live. A reused id is announced again before any row naming it, so Emacs' table is
//! bounded by what the grids can hold rather than by what the session has ever seen.
//!
//! A store nobody collects -- the grid-less [`Filter`](super::stream::Filter) -- falls
//! back on the caps below, which drop whole entries least-recently-used first without
//! ever reusing the id. An id whose URI has been dropped renders as ordinary text with
//! no destination, the same degradation an evicted image gets.

use std::collections::HashMap;

use super::fast_hash;
use super::intern::{Ledger, dense_id};

dense_id! {
    /// The wire name for one distinct hyperlink destination.
    ///
    /// A dense index rather than the hash itself, so a cell's link is four bytes. The hash
    /// decides *which* index — see [`LinkStore::intern`].
    pub struct LinkId;
}

/// Distinct destinations whose URIs are remembered.
///
/// `ls --hyperlink` over a large directory is the case this is sized for: one entry
/// per file, and the screen holds a few hundred at a time, so a few thousand is
/// several screens of history deep.
pub(crate) const MAX_TRACKED_LINKS: usize = 4096;

/// Total URI bytes held before the oldest entries are dropped.
///
/// The image store holds no payload at all -- Emacs does, and is told when it drops one
/// -- but a URI is small enough to keep and cheap enough to compare, which is what closes
/// the collision hole a hostile child could otherwise aim at a hyperlink's destination.
/// So the bytes stay here, bounded twice: [`MAX_URI_LEN`] per URI, and this for the
/// pathological case of thousands of long ones.
pub(crate) const MAX_RETAINED_URI_BYTES: usize = 4 << 20;

/// Longest URI accepted from the child.
///
/// The OSC 8 specification asks terminals to support "at least 2083 bytes" and to
/// ignore anything longer rather than truncating it — a truncated URI is a different
/// destination, which is worse than no destination. Doubled here, and enforced in
/// [`super::term`] rather than relying on the generic OSC payload limit, because the
/// hyperlink arm returns before that check.
pub(crate) const MAX_URI_LEN: usize = 4096;

/// The hyperlink destinations this terminal knows about.
#[derive(Debug)]
pub(crate) struct LinkStore {
    /// Ids, hash buckets and LRU order; see [`Ledger`].
    ledger: Ledger<LinkId>,
    uris: HashMap<LinkId, String>,
    bytes: usize,
    /// How many destinations are held before the caller is asked to collect, and past
    /// which [`LinkStore::evict`] drops entries outright. Starts at
    /// [`MAX_TRACKED_LINKS`] and grows when a collection frees too little, exactly as
    /// `StyleStore::limit` does, so a screen genuinely showing more links than the cap
    /// does not collect on every one of them.
    limit: usize,
}

impl Default for LinkStore {
    fn default() -> Self {
        Self {
            ledger: Ledger::default(),
            uris: HashMap::new(),
            bytes: 0,
            limit: MAX_TRACKED_LINKS,
        }
    }
}

impl LinkStore {
    /// A store that looks for ids to free once LIMIT destinations are held, rather than
    /// at the four thousand an ordinary one holds.
    ///
    /// For a property test to reach id reuse at all, which is where the contract lives:
    /// with a limit of four a collection runs every few `OSC 8`s, so an id a collection
    /// wrongly freed is soon naming another destination while a cell still holds it.
    pub(crate) fn with_limit(limit: usize) -> Self {
        Self {
            limit,
            ..Self::default()
        }
    }

    /// Whether giving another destination an id should wait for a collection first.
    ///
    /// Asked by the caller, because collecting needs the grids and this does not have
    /// them; `State::hyperlink` is where the two meet.
    pub(crate) fn is_full(&self) -> bool {
        self.ledger.len() >= self.limit
    }

    /// Free every id MARK does not report, so it can be handed to another destination.
    ///
    /// MARK is handed a function to call with each id still referenced and must report
    /// every place one can be held until the next collection. `State::collect_links`
    /// is that list; an id it missed would be handed out again while a cell still named
    /// it, and that cell would render with the new destination.
    ///
    /// The same shape as [`StyleStore::collect`](super::style::StyleStore::collect) and
    /// for the same reasons, with one difference: a rendition is a *value* the marked
    /// tables hold, while a URI is text Emacs has already been given, so nothing has to
    /// be paid out before an id changes meaning. `cooked--install-links' takes the
    /// redefinition and the text keeps the destination it was rendered with.
    pub(crate) fn collect(&mut self, mark: impl FnOnce(&mut dyn FnMut(LinkId))) {
        let mut live = std::collections::HashSet::with_capacity(self.ledger.len());
        mark(&mut |id: LinkId| {
            live.insert(id);
        });
        let dead: Vec<LinkId> = self.ledger.lru().filter(|id| !live.contains(id)).collect();
        for id in dead {
            self.ledger.free(id);
            if let Some(uri) = self.uris.remove(&id) {
                self.bytes -= uri.len();
            }
        }
        // Half full after a collection is the point to grow rather than collect again on
        // the next few links, which would make a screenful of distinct destinations
        // quadratic. `StyleStore::collect` grows for the same reason.
        self.limit = self.limit.max(self.ledger.len() * 2);
    }

    /// Take URI as a destination, returning its id and whether Lisp has yet to see it.
    ///
    /// The same URI always comes back with the same id and `false`, which is what makes
    /// the common shapes cheap: a program that colours a link as it prints it re-emits
    /// the whole `OSC 8` sequence per line, and only the first of those crosses.
    ///
    /// This is also the whole answer to OSC 8's `id=` parameter, which is deliberately
    /// ignored. That parameter exists so a client can tell a terminal that two
    /// non-adjacent spans are one link, for hover highlighting; content-addressing
    /// gives "same destination, same id" for free, and the case `id=` adds on top of
    /// that — two spans with the *same* destination that should nonetheless highlight
    /// separately — is not one anything renders differently here.
    ///
    /// The hash only narrows the search to a bucket; every candidate is compared against
    /// the actual URI. The fast hash makes no promise against a deliberately searched
    /// collision, so this comparison is what keeps two URIs from sharing an id.
    pub(crate) fn intern(&mut self, uri: &str) -> (LinkId, bool) {
        let hash = fast_hash(uri.as_bytes());
        if let Some(id) = self
            .ledger
            .find(hash, |id| self.uris.get(&id).is_some_and(|u| u == uri))
        {
            return (id, false);
        }

        let id = self.ledger.insert(hash);
        self.bytes += uri.len();
        self.uris.insert(id, uri.to_owned());
        self.evict();
        (id, true)
    }

    /// The URI behind an id.
    ///
    /// A session's drain never asks: it sends each URI once, as `:links', and Lisp holds
    /// the table thereafter. The grid-less [`Filter`](crate::emu::stream::Filter) does,
    /// on every link span it emits, because the consumer on its side is a comint buffer
    /// with no session to hold such a table -- so the destination crosses the boundary
    /// as text rather than as an id. See `cooked-process--text', which is where the
    /// reasoning about ids that resolve only inside a session is written out.
    pub(crate) fn get(&self, id: LinkId) -> Option<&str> {
        self.uris.get(&id).map(String::as_str)
    }

    /// Drop whole entries, oldest first, until both caps are met.
    ///
    /// One pass rather than the image store's two, because there is nothing here to
    /// split: an image keeps geometry after its payload goes, and a hyperlink is
    /// nothing but its payload.
    fn evict(&mut self) {
        while self.ledger.len() > self.limit || self.bytes > MAX_RETAINED_URI_BYTES {
            let Some(id) = self.ledger.evict_oldest() else {
                break;
            };
            if let Some(uri) = self.uris.remove(&id) {
                self.bytes -= uri.len();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_same_uri_interns_once() {
        let mut store = LinkStore::default();
        let (first, fresh) = store.intern("https://example.com/");
        assert!(fresh);
        let (again, fresh) = store.intern("https://example.com/");
        assert_eq!(first, again);
        assert!(!fresh, "Lisp already has this one");
        let (other, fresh) = store.intern("https://example.org/");
        assert_ne!(first, other);
        assert!(fresh);
        assert_eq!(store.get(first), Some("https://example.com/"));
    }

    #[test]
    fn eviction_takes_the_hash_with_the_entry() {
        let mut store = LinkStore::default();
        let first = store.intern("https://example.com/0").0;
        for i in 1..=MAX_TRACKED_LINKS {
            store.intern(&format!("https://example.com/{i}"));
        }
        assert_eq!(store.get(first), None, "the oldest went");
        // The point of the `by_hash` sweep: the same URI again is a *new* id with text
        // behind it, not the stale id whose text was dropped.
        let (again, fresh) = store.intern("https://example.com/0");
        assert!(fresh);
        assert_ne!(again, first);
        assert_eq!(store.get(again), Some("https://example.com/0"));
    }

    #[test]
    fn a_collection_frees_only_what_nothing_marks_and_the_id_is_handed_out_again() {
        let mut store = LinkStore::default();
        let kept = store.intern("https://kept.example/").0;
        let dropped = store.intern("https://dropped.example/").0;
        store.collect(|mark| mark(kept));
        assert_eq!(
            store.get(kept),
            Some("https://kept.example/"),
            "still named"
        );
        assert_eq!(store.get(dropped), None, "nothing named it");

        // The freed id comes back, and comes back announced: `fresh` is what puts it in
        // the drain's `:links', so Emacs replaces what the id meant before rendering a
        // row that names it.
        let (reused, fresh) = store.intern("https://third.example/");
        assert_eq!(reused, dropped, "the freed id is reused");
        assert!(fresh);
        assert_eq!(store.get(reused), Some("https://third.example/"));
        assert_eq!(
            store.intern("https://kept.example/"),
            (kept, false),
            "and the live entry is untouched by any of it"
        );
    }

    /// The id space is what the packed cell rests on, so this pins the shape of the
    /// bound: with a collector, distinct destinations cost ids only while they are live.
    #[test]
    fn churning_destinations_costs_no_ids_while_nothing_is_live() {
        let mut store = LinkStore::default();
        let mut highest = 0;
        for i in 0..MAX_TRACKED_LINKS * 4 {
            let id = store.intern(&format!("https://example.com/{i}")).0;
            highest = highest.max(id.index());
            // Nothing names the id once the next one is interned, which is what a cell
            // being overwritten does to it.
            store.collect(|_mark| {});
        }
        assert_eq!(highest, 0, "one id, handed back and out again");
    }

    #[test]
    fn the_byte_cap_bounds_the_store_too() {
        let mut store = LinkStore::default();
        let uri = "x".repeat(MAX_URI_LEN);
        for i in 0..(MAX_RETAINED_URI_BYTES / MAX_URI_LEN + 8) {
            store.intern(&format!("{i}{uri}"));
        }
        assert!(store.bytes <= MAX_RETAINED_URI_BYTES);
        assert_eq!(store.ledger.tracked(), store.uris.len());
    }

    /// A real fast-hash collision is expensive to find by brute force in a unit test, so
    /// this plants one directly: a decoy id occupies the bucket a real URI would hash
    /// into, with different text behind it. Trusting the bucket would return the decoy as
    /// if it were the real URI, silently pointing the link at the decoy's destination.
    #[test]
    fn a_shared_hash_bucket_does_not_alias_a_different_uri() {
        let mut store = LinkStore::default();
        let decoy = LinkId::from_index(999);
        store
            .uris
            .insert(decoy, "https://decoy.example/".to_owned());
        let hash = fast_hash(b"https://real.example/");
        store.ledger.plant(hash, decoy);

        let (id, fresh) = store.intern("https://real.example/");
        assert!(
            fresh,
            "a same-bucket decoy with different text is not a match"
        );
        assert_ne!(id, decoy);
        assert_eq!(store.get(id), Some("https://real.example/"));
        assert_eq!(
            store.get(decoy),
            Some("https://decoy.example/"),
            "untouched"
        );
    }
}
