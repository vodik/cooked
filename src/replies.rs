//! Bytes the terminal owes the child, queued so that sending them never waits on it.
//!
//! A reply used to be written on Emacs' thread the moment Lisp handled it, polling for up
//! to `WRITE_TIMEOUT` when the pty's input queue was full. A child that stops reading --
//! stopped with `C-z`, sitting in a debugger, or simply hung in raw mode -- fills that
//! queue after a few thousand mode 2048 reports, and from then on every resize and every
//! answer froze Emacs for three seconds. Here a reply is appended to a [`ReplyQueue`] and
//! written as far as the pty takes it without blocking; the reader thread finishes the
//! rest when the pty says it has room.
//!
//! The queue is plain data: it decides what is kept, what is dropped and where the next
//! write starts, and takes the write itself as a closure. That is what lets the policy be
//! tested without a child, and it keeps every syscall in `session`.

use crate::emu::ReplyKind;
use std::collections::VecDeque;

/// Queued bytes past which a further reply is dropped rather than kept.
///
/// A child that is reading never comes near this: the pty itself holds tens of kilobytes
/// of input, and a reply is written the moment it is queued. The queue only grows while
/// the pty is full, which means the child has not read anything for as long as it took to
/// fill both, so what matters is that the memory stops growing, not where exactly.
///
/// A megabyte sits well above the largest reply anything composes: an OSC 52 answer is
/// capped by `cooked-clipboard-max-size', 100,000 characters by default. A reply bigger
/// than this is still admitted into an empty queue, so raising that option cannot make
/// the clipboard unreadable; the bound is then one reply rather than this number.
pub(crate) const REPLY_QUEUE_LIMIT: usize = 1 << 20;

/// One reply's place in [`ReplyQueue::bytes`].
#[derive(Debug, Clone, Copy)]
struct Entry {
    len: usize,
    kind: ReplyKind,
}

/// Replies not yet written to the pty, oldest first.
///
/// The bytes are held contiguously, so everything queued goes out in one `write` however
/// many replies it is made of: a palette query for all 256 entries is answered with one
/// syscall rather than 256.
#[derive(Debug, Default)]
pub(crate) struct ReplyQueue {
    /// Every unfinished reply, oldest first, including the part of the oldest that has
    /// already gone out.
    bytes: Vec<u8>,
    /// How long each reply in `bytes` is, oldest first.
    entries: VecDeque<Entry>,
    /// How much of the oldest reply has already been written.
    ///
    /// A reply is never dropped or replaced once it has started to go out, because the
    /// child would read the half that was sent run into whatever follows it.
    started: usize,
}

impl ReplyQueue {
    /// Queue BYTES, reporting whether they were kept.
    ///
    /// A size report first removes any older one that has not started to go out. After
    /// that, a reply that would take the queue past [`REPLY_QUEUE_LIMIT`] is dropped,
    /// unless the queue is empty. The newest reply is the one dropped, never an older
    /// one: the child reads the queue front to back, so the answers it already asked for
    /// arrive whole and in order, and only a question asked after it stopped reading goes
    /// unanswered.
    pub(crate) fn push(&mut self, kind: ReplyKind, bytes: &[u8]) -> bool {
        if bytes.is_empty() {
            return true;
        }
        if kind == ReplyKind::SizeReport {
            self.remove_unstarted(ReplyKind::SizeReport);
        }
        if !self.is_empty() && self.len() + bytes.len() > REPLY_QUEUE_LIMIT {
            return false;
        }
        self.bytes.extend_from_slice(bytes);
        self.entries.push_back(Entry {
            len: bytes.len(),
            kind,
        });
        true
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// How many bytes are waiting to be written.
    pub(crate) fn len(&self) -> usize {
        self.bytes.len() - self.started
    }

    /// Hand everything waiting to WRITE at once, and forget what it took.
    ///
    /// WRITE answers how many bytes it accepted, 0 when the pty is full. It is called at
    /// most once, so a flush never loops on a child that is not reading. An error is
    /// returned as it came, with the queue emptied: the ways a write to the master fails
    /// other than a full queue are a child that has gone, and nobody is left to read the
    /// rest.
    pub(crate) fn flush<E>(
        &mut self,
        write: impl FnOnce(&[u8]) -> std::result::Result<usize, E>,
    ) -> std::result::Result<(), E> {
        if self.is_empty() {
            return Ok(());
        }
        match write(&self.bytes[self.started..]) {
            Ok(n) => {
                self.consume(n.min(self.len()));
                Ok(())
            }
            Err(e) => {
                self.clear();
                Err(e)
            }
        }
    }

    pub(crate) fn clear(&mut self) {
        self.bytes.clear();
        self.entries.clear();
        self.started = 0;
    }

    /// Note that the pty took the next N bytes, and forget the replies now finished.
    fn consume(&mut self, n: usize) {
        self.started += n;
        let mut finished = 0;
        while let Some(front) = self.entries.front()
            && self.started >= front.len
        {
            self.started -= front.len;
            finished += front.len;
            self.entries.pop_front();
        }
        self.bytes.drain(..finished);
    }

    /// Drop every reply of KIND that has not started to go out.
    fn remove_unstarted(&mut self, kind: ReplyKind) {
        let started = self.started;
        let doomed =
            |index: usize, entry: &Entry| entry.kind == kind && !(index == 0 && started > 0);
        if !self.entries.iter().enumerate().any(|(i, e)| doomed(i, e)) {
            return;
        }
        // Rebuilt rather than cut in place, which would move every later byte once per
        // removal.
        let mut kept = Vec::with_capacity(self.bytes.len());
        let mut entries = VecDeque::with_capacity(self.entries.len());
        let mut offset = 0;
        for (index, entry) in self.entries.iter().enumerate() {
            if !doomed(index, entry) {
                kept.extend_from_slice(&self.bytes[offset..offset + entry.len]);
                entries.push_back(*entry);
            }
            offset += entry.len;
        }
        // Only a reply that had not started can have gone from the front, so a front
        // that went leaves nothing partly written.
        if self.entries.front().is_some_and(|e| doomed(0, e)) {
            self.started = 0;
        }
        self.bytes = kept;
        self.entries = entries;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Write everything WRITE is given, recording it.
    fn drain_into(queue: &mut ReplyQueue, sink: &mut Vec<u8>) {
        queue
            .flush(|bytes| -> std::result::Result<usize, ()> {
                sink.extend_from_slice(bytes);
                Ok(bytes.len())
            })
            .unwrap();
    }

    #[test]
    fn replies_go_out_in_the_order_they_were_queued_in_one_write() {
        let mut queue = ReplyQueue::default();
        for n in 0..256 {
            assert!(queue.push(
                ReplyKind::Answer,
                format!("\x1b]4;{n};rgb:0/0/0\x07").as_bytes()
            ));
        }
        let mut writes = Vec::new();
        queue
            .flush(|bytes| -> std::result::Result<usize, ()> {
                writes.push(bytes.to_vec());
                Ok(bytes.len())
            })
            .unwrap();
        assert_eq!(writes.len(), 1);
        let want: String = (0..256)
            .map(|n| format!("\x1b]4;{n};rgb:0/0/0\x07"))
            .collect();
        assert_eq!(writes[0], want.into_bytes());
        assert!(queue.is_empty());
    }

    #[test]
    fn a_partial_write_resumes_where_the_pty_stopped() {
        let mut queue = ReplyQueue::default();
        queue.push(ReplyKind::Answer, b"\x1b[?62;4;22c");
        queue.push(ReplyKind::Answer, b"\x1b[0n");
        queue
            .flush(|_| -> std::result::Result<usize, ()> { Ok(5) })
            .unwrap();
        assert_eq!(queue.len(), 11 + 4 - 5);
        let mut sink = Vec::new();
        drain_into(&mut queue, &mut sink);
        assert_eq!(sink, b";4;22c\x1b[0n");
    }

    #[test]
    fn a_full_pty_keeps_everything_queued() {
        let mut queue = ReplyQueue::default();
        queue.push(ReplyKind::Answer, b"\x1b[0n");
        queue
            .flush(|_| -> std::result::Result<usize, ()> { Ok(0) })
            .unwrap();
        assert_eq!(queue.len(), 4);
    }

    #[test]
    fn a_failed_write_empties_the_queue() {
        let mut queue = ReplyQueue::default();
        queue.push(ReplyKind::Answer, b"\x1b[0n");
        assert_eq!(queue.flush(|_| Err("EIO")), Err("EIO"));
        assert!(queue.is_empty());
    }

    #[test]
    fn a_child_that_never_reads_cannot_grow_the_queue_past_the_limit() {
        let mut queue = ReplyQueue::default();
        let reply = b"\x1b[?62;4;22c";
        let mut kept = 0;
        for _ in 0..(2 * REPLY_QUEUE_LIMIT / reply.len()) {
            kept += usize::from(queue.push(ReplyKind::Answer, reply));
        }
        assert!(queue.len() <= REPLY_QUEUE_LIMIT);
        assert_eq!(kept, REPLY_QUEUE_LIMIT / reply.len());
        // What is kept is the oldest, whole: the queue is a prefix of what was asked.
        let mut sink = Vec::new();
        drain_into(&mut queue, &mut sink);
        assert_eq!(sink, reply.repeat(kept));
    }

    #[test]
    fn one_reply_larger_than_the_limit_is_still_admitted_alone() {
        let mut queue = ReplyQueue::default();
        let big = vec![b'x'; REPLY_QUEUE_LIMIT + 1];
        assert!(queue.push(ReplyKind::Answer, &big));
        assert!(!queue.push(ReplyKind::Answer, b"\x1b[0n"));
        assert_eq!(queue.len(), big.len());
    }

    #[test]
    fn a_size_report_replaces_one_that_has_not_started() {
        let mut queue = ReplyQueue::default();
        queue.push(ReplyKind::SizeReport, b"\x1b[48;24;80;0;0t");
        queue.push(ReplyKind::Answer, b"\x1b[0n");
        for rows in 25..10_025 {
            queue.push(
                ReplyKind::SizeReport,
                format!("\x1b[48;{rows};80;0;0t").as_bytes(),
            );
        }
        let mut sink = Vec::new();
        drain_into(&mut queue, &mut sink);
        assert_eq!(sink, b"\x1b[0n\x1b[48;10024;80;0;0t");
    }

    #[test]
    fn a_size_report_already_going_out_is_finished_first() {
        let mut queue = ReplyQueue::default();
        queue.push(ReplyKind::SizeReport, b"\x1b[48;24;80;0;0t");
        queue
            .flush(|_| -> std::result::Result<usize, ()> { Ok(3) })
            .unwrap();
        queue.push(ReplyKind::Answer, b"\x1b[0n");
        queue.push(ReplyKind::SizeReport, b"\x1b[48;30;90;0;0t");
        queue.push(ReplyKind::SizeReport, b"\x1b[48;40;90;0;0t");
        let mut sink = Vec::new();
        drain_into(&mut queue, &mut sink);
        assert_eq!(sink, b"8;24;80;0;0t\x1b[0n\x1b[48;40;90;0;0t");
    }
}
