//! The bookkeeping the content-addressed stores share.
//!
//! [`ImageStore`](super::image::ImageStore) and [`LinkStore`](super::link::LinkStore) are
//! the same idea twice: hash the content, narrow to a bucket, compare properly, hand back
//! a dense id, and evict least-recently-used. Written out, they were field-for-field
//! identical in four places and the ordering was character-for-character the same code.
//!
//! What is *not* shared is what each keeps against an id -- a link is nothing but its URI,
//! while an image keeps geometry that outlives its payload, and evicts the two separately.
//! So this owns the ids and the ordering, and each store layers its own tables on top.

use std::collections::HashMap;
use std::hash::Hash;

/// A dense id handed out by a [`Ledger`].
pub(crate) trait Id: Copy + Eq + Hash {
    fn from_index(index: u32) -> Self;
}

/// One id's place in the ordering, and the bucket it was filed under.
///
/// `older`/`newer` make [`Ledger::entries`] a doubly-linked list threaded through the map
/// -- an id rather than a pointer, which is what lets the list live in safe code and in a
/// `HashMap` that reallocates underneath it.
#[derive(Debug)]
struct Entry<K> {
    /// Which bucket of [`Ledger::by_hash`] this id sits in.
    ///
    /// Carried per entry purely so eviction can unfile an id in one lookup. Without it
    /// the only way back from an id to its bucket is to search every bucket, which is
    /// what [`Ledger::evict_oldest`] used to do.
    hash: u64,
    /// Towards the least-recently-used end; `None` at it.
    older: Option<K>,
    /// Towards the most-recently-used end; `None` at it.
    newer: Option<K>,
}

/// Ids, their hash buckets, and their least-recently-used order.
///
/// The order is an intrusive doubly-linked list rather than a `VecDeque`, and both of the
/// operations that touch it are O(1) as a result. As a deque they were not, and both were
/// on paths a child can drive:
///
/// - Re-using an entry had to find it in the order before moving it to the end, which was
///   a scan of every id held. `ls --hyperlink=auto` re-emits a link's whole `OSC 8`
///   sequence per line, so that scan ran per line of output.
/// - Eviction had to unfile the id from its bucket, and with no record of *which* bucket,
///   the only way was `by_hash.retain(..)` over every bucket in the map. At the cap, where
///   each insert evicts, that made a directory of links quadratic in the number of them.
#[derive(Debug)]
pub(crate) struct Ledger<K> {
    /// A hash bucket, not the identity itself. More than one entry only when two distinct
    /// payloads happen to share a hash, which is why [`Ledger::find`] still compares
    /// properly before treating a hit as the same content.
    by_hash: HashMap<u64, Vec<K>>,
    /// Every live id, and its neighbours in the order. The list's own storage: `entries`
    /// is what `older`/`newer` index into.
    entries: HashMap<K, Entry<K>>,
    /// The least-recently-used end, which is where eviction takes from.
    oldest: Option<K>,
    /// The most-recently-used end, which is where a fresh or re-used id goes.
    newest: Option<K>,
    next: u32,
}

impl<K> Default for Ledger<K> {
    fn default() -> Self {
        Self {
            by_hash: HashMap::new(),
            entries: HashMap::new(),
            oldest: None,
            newest: None,
            next: 0,
        }
    }
}

impl<K: Id> Ledger<K> {
    /// The id in `hash`'s bucket that `matches` accepts, moved to the most-recently-used
    /// end on the way out.
    ///
    /// Finding and touching are one call rather than two because the two were never
    /// separately useful: both stores looked up and then unconditionally touched, and a
    /// caller that forgot the second half would get a silently wrong eviction order --
    /// the entry a child is using every line would be the one aged out. Nothing here can
    /// be half-used now.
    ///
    /// They were split because a `&mut self` receiver appeared to conflict with a
    /// `matches` closure reading the caller's own value map. Closure captures have been
    /// field-precise since edition 2021, so `self.ledger.find(|id| self.uris..)` borrows
    /// the two fields disjointly and the constraint that forced the split is gone.
    pub(crate) fn find(&mut self, hash: u64, matches: impl Fn(K) -> bool) -> Option<K> {
        let id = self
            .by_hash
            .get(&hash)?
            .iter()
            .copied()
            .find(|&id| matches(id))?;
        self.touch(id);
        Some(id)
    }

    /// Hand out the next id, file it under `hash`, and make it most-recently-used.
    pub(crate) fn insert(&mut self, hash: u64) -> K {
        let id = K::from_index(self.next);
        self.next = self.next.wrapping_add(1);
        self.by_hash.entry(hash).or_default().push(id);
        self.link_newest(id, hash);
        id
    }

    /// Take the least-recently-used id, forgetting its hash along with it.
    ///
    /// The hash goes too, and that is load-bearing rather than tidy: leaving it behind
    /// would make a later, identical payload resolve to an id whose content has gone.
    pub(crate) fn evict_oldest(&mut self) -> Option<K> {
        let id = self.oldest?;
        let entry = self.unlink(id)?;
        // The one bucket it was in, named by the entry rather than searched for.
        if let Some(bucket) = self.by_hash.get_mut(&entry.hash) {
            bucket.retain(|&v| v != id);
            if bucket.is_empty() {
                self.by_hash.remove(&entry.hash);
            }
        }
        Some(id)
    }

    /// Every id, least-recently-used first, without disturbing the order.
    ///
    /// For a store that sheds part of an entry before shedding the entry itself.
    pub(crate) fn lru(&self) -> impl Iterator<Item = K> + '_ {
        std::iter::successors(self.oldest, |&id| {
            self.entries.get(&id).and_then(|entry| entry.newer)
        })
    }

    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    /// Move `id` to the most-recently-used end, or do nothing if it is not held.
    ///
    /// Doing nothing is what the collision tests rely on: [`Ledger::plant`] files an id in
    /// a bucket without an entry, so it has no place in the order to move.
    fn touch(&mut self, id: K) {
        if self.newest == Some(id) {
            return;
        }
        if let Some(entry) = self.unlink(id) {
            self.link_newest(id, entry.hash);
        }
    }

    /// Take `id` out of the order, returning what it held.
    fn unlink(&mut self, id: K) -> Option<Entry<K>> {
        let entry = self.entries.remove(&id)?;
        match entry.older {
            Some(older) => {
                if let Some(e) = self.entries.get_mut(&older) {
                    e.newer = entry.newer;
                }
            }
            None => self.oldest = entry.newer,
        }
        match entry.newer {
            Some(newer) => {
                if let Some(e) = self.entries.get_mut(&newer) {
                    e.older = entry.older;
                }
            }
            None => self.newest = entry.older,
        }
        Some(entry)
    }

    /// Put `id` at the most-recently-used end. It must not currently be in the order.
    fn link_newest(&mut self, id: K, hash: u64) {
        let older = self.newest;
        match older {
            Some(prev) => {
                if let Some(e) = self.entries.get_mut(&prev) {
                    e.newer = Some(id);
                }
            }
            None => self.oldest = Some(id),
        }
        self.newest = Some(id);
        self.entries.insert(
            id,
            Entry {
                hash,
                older,
                newer: None,
            },
        );
    }

    /// Total ids across all buckets, for the tests that check nothing is left stranded.
    #[cfg(test)]
    pub(crate) fn tracked(&self) -> usize {
        self.by_hash.values().map(Vec::len).sum()
    }

    /// File `id` under `hash` without handing out a new one, or giving it a place in the
    /// order.
    ///
    /// Only the collision tests use this: a real fast-hash collision is expensive to find
    /// by brute force, so they plant one.
    #[cfg(test)]
    pub(crate) fn plant(&mut self, hash: u64, id: K) {
        self.by_hash.entry(hash).or_default().push(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    struct TestId(u32);

    impl Id for TestId {
        fn from_index(index: u32) -> Self {
            Self(index)
        }
    }

    /// The order as `lru` reports it, which is the only view either store has of it.
    fn order(ledger: &Ledger<TestId>) -> Vec<u32> {
        ledger.lru().map(|TestId(i)| i).collect()
    }

    /// Both ends and every link, walked from both directions. The list is threaded through
    /// a map by id, so a broken splice shows up as a chain that disagrees with itself
    /// rather than as a crash -- which no assertion on `lru` alone would catch, that
    /// walking only `newer`.
    fn check(ledger: &Ledger<TestId>) {
        let forward = order(ledger);
        assert_eq!(forward.len(), ledger.len(), "lru must reach every entry");
        let mut backward: Vec<u32> =
            std::iter::successors(ledger.newest, |&id| ledger.entries[&id].older)
                .map(|TestId(i)| i)
                .collect();
        backward.reverse();
        assert_eq!(forward, backward, "the two directions must agree");
        if let Some(oldest) = ledger.oldest {
            assert!(ledger.entries[&oldest].older.is_none());
        }
        if let Some(newest) = ledger.newest {
            assert!(ledger.entries[&newest].newer.is_none());
        }
        assert_eq!(forward.is_empty(), ledger.oldest.is_none());
        assert_eq!(forward.is_empty(), ledger.newest.is_none());
    }

    #[test]
    fn insertion_order_is_the_initial_lru_order() {
        let mut ledger = Ledger::<TestId>::default();
        for h in 0..4 {
            ledger.insert(h);
        }
        check(&ledger);
        assert_eq!(order(&ledger), [0, 1, 2, 3]);
    }

    #[test]
    fn finding_an_entry_makes_it_newest() {
        let mut ledger = Ledger::<TestId>::default();
        for h in 0..4 {
            ledger.insert(h);
        }
        // From the middle, from the oldest end, and from the newest end, which is the
        // case `touch` short-circuits.
        assert_eq!(ledger.find(1, |_| true), Some(TestId(1)));
        check(&ledger);
        assert_eq!(order(&ledger), [0, 2, 3, 1]);
        assert_eq!(ledger.find(0, |_| true), Some(TestId(0)));
        check(&ledger);
        assert_eq!(order(&ledger), [2, 3, 1, 0]);
        assert_eq!(ledger.find(0, |_| true), Some(TestId(0)));
        check(&ledger);
        assert_eq!(order(&ledger), [2, 3, 1, 0]);
    }

    #[test]
    fn a_refused_match_is_neither_returned_nor_touched() {
        let mut ledger = Ledger::<TestId>::default();
        for h in 0..3 {
            ledger.insert(h);
        }
        assert_eq!(ledger.find(0, |_| false), None);
        check(&ledger);
        assert_eq!(order(&ledger), [0, 1, 2], "a refused hit must not reorder");
    }

    #[test]
    fn eviction_takes_the_oldest_and_unfiles_only_its_own_bucket() {
        let mut ledger = Ledger::<TestId>::default();
        for h in 0..3 {
            ledger.insert(h);
        }
        ledger.find(0, |_| true); // 0 is now newest, so 1 is the oldest
        assert_eq!(ledger.evict_oldest(), Some(TestId(1)));
        check(&ledger);
        assert_eq!(order(&ledger), [2, 0]);
        assert_eq!(ledger.tracked(), 2, "the evicted id leaves its bucket");
        assert_eq!(ledger.find(1, |_| true), None, "and its hash goes with it");
        assert_eq!(
            ledger.find(2, |_| true),
            Some(TestId(2)),
            "other buckets survive"
        );
    }

    #[test]
    fn a_shared_bucket_evicts_one_id_without_taking_the_other() {
        let mut ledger = Ledger::<TestId>::default();
        let first = ledger.insert(7);
        let second = ledger.insert(7); // same bucket, as a hash collision would be
        assert_eq!(ledger.evict_oldest(), Some(first));
        check(&ledger);
        assert_eq!(ledger.tracked(), 1);
        assert_eq!(
            ledger.find(7, |_| true),
            Some(second),
            "the surviving id keeps its bucket"
        );
    }

    #[test]
    fn evicting_everything_empties_both_ends() {
        let mut ledger = Ledger::<TestId>::default();
        for h in 0..3 {
            ledger.insert(h);
        }
        for _ in 0..3 {
            assert!(ledger.evict_oldest().is_some());
            check(&ledger);
        }
        assert_eq!(ledger.evict_oldest(), None);
        assert_eq!(ledger.len(), 0);
        assert_eq!(ledger.tracked(), 0, "no bucket is left stranded");
        // And the emptied ledger is still usable, rather than holding a dangling end.
        ledger.insert(9);
        check(&ledger);
        assert_eq!(order(&ledger), [3]);
    }

    #[test]
    fn a_planted_id_has_no_place_in_the_order() {
        // What the two stores' collision tests rely on: a decoy occupies a bucket without
        // becoming evictable, and a `find` that reaches it must not try to move it.
        let mut ledger = Ledger::<TestId>::default();
        let real = ledger.insert(5);
        ledger.plant(5, TestId(999));
        assert_eq!(ledger.len(), 1);
        assert_eq!(ledger.find(5, |id| id == TestId(999)), Some(TestId(999)));
        check(&ledger);
        assert_eq!(order(&ledger), [real.0], "the planted id joins no order");
    }
}
