//! The bookkeeping the content-addressed stores share.
//!
//! [`ImageStore`](super::image::ImageStore) and [`LinkStore`](super::link::LinkStore) are
//! the same idea twice: hash the content, narrow to a bucket, compare properly, hand back
//! a dense id, and evict least-recently-used. Written out, they were field-for-field
//! identical in four places and `touch` was character-for-character the same function.
//!
//! What is *not* shared is what each keeps against an id -- a link is nothing but its URI,
//! while an image keeps geometry that outlives its payload, and evicts the two separately.
//! So this owns the ids and the ordering, and each store layers its own tables on top.

use std::collections::{HashMap, VecDeque};
use std::hash::Hash;

/// A dense id handed out by a [`Ledger`].
pub trait Id: Copy + Eq + Hash {
    fn from_index(index: u32) -> Self;
}

/// Ids, their hash buckets, and their least-recently-used order.
#[derive(Debug)]
pub struct Ledger<K> {
    /// A hash bucket, not the identity itself. More than one entry only when two distinct
    /// payloads happen to share a hash, which is why every caller still compares properly
    /// before treating a hit as the same content.
    by_hash: HashMap<u64, Vec<K>>,
    /// Least-recently-used first.
    ///
    /// A `VecDeque` rather than a `Vec`: eviction takes from the front, and `Vec::remove(0)`
    /// made every eviction an O(n) memmove of the whole order.
    order: VecDeque<K>,
    next: u32,
}

impl<K> Default for Ledger<K> {
    fn default() -> Self {
        Self {
            by_hash: HashMap::new(),
            order: VecDeque::new(),
            next: 0,
        }
    }
}

impl<K: Id> Ledger<K> {
    /// The id in `hash`'s bucket that `matches` accepts.
    ///
    /// Takes `&self` deliberately, even though every caller follows it with
    /// [`Ledger::touch`]: folding the touch in here would make this `&mut self`, and a
    /// caller whose `matches` closure reads its own value map would then have to
    /// pre-borrow that map to keep the two borrows disjoint. Shared here, both are.
    pub fn lookup(&self, hash: u64, matches: impl Fn(K) -> bool) -> Option<K> {
        self.by_hash
            .get(&hash)?
            .iter()
            .copied()
            .find(|&id| matches(id))
    }

    /// Hand out the next id and file it under `hash`.
    pub fn insert(&mut self, hash: u64) -> K {
        let id = K::from_index(self.next);
        self.next = self.next.wrapping_add(1);
        self.by_hash.entry(hash).or_default().push(id);
        self.order.push_back(id);
        id
    }

    /// Move `id` to the most-recently-used end.
    pub fn touch(&mut self, id: K) {
        if let Some(at) = self.order.iter().position(|&i| i == id) {
            self.order.remove(at);
            self.order.push_back(id);
        }
    }

    /// Take the least-recently-used id, forgetting its hash along with it.
    ///
    /// The hash goes too, and that is load-bearing rather than tidy: leaving it behind
    /// would make a later, identical payload resolve to an id whose content has gone.
    pub fn evict_oldest(&mut self) -> Option<K> {
        let id = self.order.pop_front()?;
        self.by_hash.retain(|_, bucket| {
            bucket.retain(|&v| v != id);
            !bucket.is_empty()
        });
        Some(id)
    }

    /// Every id, least-recently-used first, without disturbing the order.
    ///
    /// For a store that sheds part of an entry before shedding the entry itself.
    pub fn lru(&self) -> impl Iterator<Item = K> + '_ {
        self.order.iter().copied()
    }

    pub fn len(&self) -> usize {
        self.order.len()
    }

    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    /// Total ids across all buckets, for the tests that check nothing is left stranded.
    pub fn tracked(&self) -> usize {
        self.by_hash.values().map(Vec::len).sum()
    }

    /// File `id` under `hash` without handing out a new one.
    ///
    /// Only the collision tests use this: a real fast-hash collision is expensive to find
    /// by brute force, so they plant one.
    #[cfg(test)]
    pub fn plant(&mut self, hash: u64, id: K) {
        self.by_hash.entry(hash).or_default().push(id);
    }
}
