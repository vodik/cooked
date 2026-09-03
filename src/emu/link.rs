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
//! **Lifetime is Emacs'.** Scrollback lives in the Emacs buffer, so a row carrying a
//! link id can leave the emulator and go on being displayed for the rest of the
//! session. Rust cannot know when the last reference dies, and does not have to: the
//! caps below are a bound on this store, not a release protocol. An id whose URI has
//! been evicted renders as ordinary text with no destination, which is the same
//! degradation an evicted image gets.

use std::collections::HashMap;

use super::fast_hash;
use super::intern::{Id, Ledger};

/// The wire name for one distinct hyperlink destination.
///
/// A dense index rather than the hash itself, so an [`super::Extra::Link`] is four
/// bytes. The hash decides *which* index — see [`LinkStore::intern`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LinkId(pub u32);

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
#[derive(Debug, Default)]
pub(crate) struct LinkStore {
    /// Ids, hash buckets and LRU order; see [`Ledger`].
    ledger: Ledger<LinkId>,
    uris: HashMap<LinkId, String>,
    bytes: usize,
}

impl Id for LinkId {
    fn from_index(index: u32) -> Self {
        Self(index)
    }
}

impl LinkStore {
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
    /// The hash only narrows the search to a bucket; every candidate in it is compared
    /// against the actual URI before being treated as the same link. Two distinct URIs
    /// that happen to share a hash therefore get distinct ids rather than one silently
    /// winning and the other's destination vanishing — the fast hash used here makes no
    /// promise against a deliberate search for such a pair, so the comparison is load-
    /// bearing, not a redundant sanity check.
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

    /// The URI behind an id. Only the eviction tests ask: a drain sends each URI once
    /// and Lisp holds the table thereafter, so the crate never looks one back up.
    #[cfg(test)]
    pub(crate) fn get(&self, id: LinkId) -> Option<&str> {
        self.uris.get(&id).map(String::as_str)
    }

    /// Drop whole entries, oldest first, until both caps are met.
    ///
    /// One pass rather than the image store's two, because there is nothing here to
    /// split: an image keeps geometry after its payload goes, and a hyperlink is
    /// nothing but its payload.
    fn evict(&mut self) {
        while self.ledger.len() > MAX_TRACKED_LINKS || self.bytes > MAX_RETAINED_URI_BYTES {
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
    /// into, with different text behind it. Before the fix this was `intern`'s only
    /// check, so the decoy would have been returned as if it were the real URI —
    /// silently pointing whoever follows the link at the decoy's destination instead.
    #[test]
    fn a_shared_hash_bucket_does_not_alias_a_different_uri() {
        let mut store = LinkStore::default();
        let decoy = LinkId(999);
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
