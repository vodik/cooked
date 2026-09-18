//! Taking a mutex without refusing over a poisoned one.

use std::sync::{Mutex, MutexGuard, PoisonError};

/// Take a lock, treating poisoning as nothing to refuse over.
///
/// Every mutex in this crate is taken this way. A poisoned mutex means a panic unwound
/// out of the emulator while it held the lock, which `env::trampoline` has already
/// reported to the user as a Lisp signal. Refusing the lock from then on would freeze
/// the buffer for good -- no drain, no resize, no teardown -- while carrying on costs at
/// worst a stale cell until the next write.
///
/// So take every lock through `held`, never through `.lock().ok()?`: that answers
/// "no" instead of recovering, and after one poisoning would leave `drain` working while
/// `alive` reported the session dead.
///
/// Named `held` rather than `take` so that `self.reader.held().take()` reads as two
/// different operations.
pub(crate) trait LockExt<T> {
    fn held(&self) -> MutexGuard<'_, T>;
}

impl<T> LockExt<T> for Mutex<T> {
    fn held(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
