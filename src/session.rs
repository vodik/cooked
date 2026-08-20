//! A running child: pty, emulator, and the reader thread that couples them to Emacs.
//!
//! Emacs' module functions may only be called from the thread holding an `emacs_env`, so
//! the reader never touches Lisp. It parses into the shared [`Term`] and pokes a pipe
//! descriptor obtained from `open_channel`; Emacs' filter then drains on the main thread.

use crate::emu::{Delta, Term};
use crate::pty::{JobControl, Mode, Pid, Pty, Winsize};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{SigSet, Signal};
use std::ffi::OsStr;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;

/// Take a lock, treating poisoning as nothing to refuse over.
///
/// Every mutex in this file is taken this way, and the uniformity is the point. A
/// poisoned mutex here means a panic unwound out of the emulator while it held the
/// lock — which `env::trampoline` has already caught and reported to the user as a
/// Lisp signal. What is left is a `Term` that may be missing an update, and the two
/// available responses are to carry on with it or to refuse the lock forever.
/// Refusing means the buffer freezes: no drain, no resize, no teardown, and a
/// terminal that has stopped repainting with no way back short of killing the
/// buffer. Carrying on means at worst a stale cell until the next write.
///
/// This used to be split. Thirteen call sites recovered the guard while six others
/// spelled the same lock `.lock().is_ok_and(..)` or `.lock().ok()?`, which silently
/// answers "no" rather than recovering — so after a poisoning `drain` kept working
/// while `bracketed_paste` reported false forever and `alive` reported the session
/// dead. One policy, stated once, is the whole reason this trait exists.
trait LockExt<T> {
    fn take(&self) -> MutexGuard<'_, T>;
}

impl<T> LockExt<T> for Mutex<T> {
    fn take(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

const READ_CHUNK: usize = 64 * 1024;
const POLL_TIMEOUT_MS: u8 = 100;
/// How long to wait for a child that closed the pty to become reapable.
const REAP_PATIENCE: std::time::Duration = std::time::Duration::from_millis(500);
/// How long an explicit shutdown gives the child to honour SIGHUP before SIGKILL,
/// and again to become reapable afterwards.
const KILL_GRACE: std::time::Duration = std::time::Duration::from_millis(50);

/// A snapshot handed to Lisp on each drain.
pub struct Update {
    pub delta: Delta,
    pub mode: Mode,
    pub exit: Option<i32>,
}

struct Shared {
    pty: Pty,
    term: Mutex<Term>,
    mode: AtomicU8,
    /// A size the child is not yet known to have, for the reader thread to keep applying
    /// until it sticks. `None` once the tty agrees. See `Session::resize`.
    pending_resize: Mutex<Option<Winsize>>,
    /// Set when output or a mode change has not yet been announced over the wake pipe;
    /// cleared once `flush_notify` actually writes. Distinct from `notified`: this tracks
    /// whether there is anything new to say, that one tracks whether we have already said
    /// it and Emacs has not yet drained.
    dirty: AtomicBool,
    /// Set when a wakeup byte is in flight; cleared by the drain, so a burst of output
    /// costs one write and one Lisp callback rather than thousands.
    notified: AtomicBool,
    /// When the wake pipe was last actually written to, for `min_redisplay_interval`.
    last_notified: Mutex<Option<std::time::Instant>>,
    /// While set and unexpired, the child is mid-frame under DEC mode 2026 and has asked
    /// not to be drawn yet. Refreshed from `Term` under the lock the reader already holds,
    /// so no path takes an extra one. See [`flush_pending`] and [`poll_timeout`].
    sync_until: Mutex<Option<std::time::Instant>>,
    /// Floor on how often the wake pipe is written to, regardless of how fast output
    /// arrives. Without one, a program that rewrites the same line rapidly — a spinner, a
    /// progress meter — drives one full Emacs redisplay per write, which is a lot more
    /// redraws than any of them are actually meant to be seen at and shows up as flicker.
    /// No matching ceiling is needed the way `eat-maximum-latency` provides one: `Term`
    /// always holds the latest state regardless of whether a wakeup was sent for it, and
    /// `flush_pending` is retried every reader-thread tick — see [`poll_timeout`], which
    /// shortens that tick to this interval's own remaining window rather than leaving a
    /// throttled notification to wait out the coarser `POLL_TIMEOUT_MS`.
    min_redisplay_interval: std::time::Duration,
    /// Pending items — scrolled-off lines plus undelivered events — at which the reader
    /// stops pulling from the pty and lets the child block. Raising it does not make
    /// rendering faster, since throughput is bounded by Emacs rather than by this queue;
    /// it lets a child run ahead and exit sooner instead of blocking in `write`, at the
    /// cost of memory and a larger worst-case redisplay when one drain finally lands.
    /// Tuned together with `min_redisplay_interval`: a longer interval leaves more to
    /// accumulate between drains, so this fills sooner.
    backlog_limit: usize,
    shutdown: AtomicBool,
    quit: Quit,
    exited: Mutex<Option<i32>>,
}

/// A self-pipe the reader polls alongside the pty, so teardown does not have to wait out
/// the poll timeout. Without it every kill blocks Emacs for up to [`POLL_TIMEOUT_MS`],
/// which is the difference between closing a buffer feeling instant and feeling like a
/// stutter.
struct Quit {
    read: OwnedFd,
    write: OwnedFd,
}

impl Quit {
    fn new() -> io::Result<Self> {
        // O_CLOEXEC, so this does not reintroduce the inherited fd `Pty::spawn` just went
        // to the trouble of closing. O_NONBLOCK so a wake can never park teardown behind a
        // full pipe.
        let (read, write) = crate::compat::cloexec_pipe()?;
        Ok(Self { read, write })
    }

    fn wake(&self) {
        let _ = nix::unistd::write(self.write.as_fd(), b"q");
    }
}

impl Shared {
    fn store_mode(&self, mode: Mode) {
        self.mode.store(mode as u8, Ordering::Relaxed);
    }

    fn load_mode(&self) -> Mode {
        match self.mode.load(Ordering::Relaxed) {
            0 => Mode::Cooked,
            1 => Mode::Raw,
            _ => Mode::Secret,
        }
    }
}

/// A live child, its emulator, and the reader thread coupling them to Emacs.
///
/// The owned resources sit behind mutexes rather than in plain `Option`s because
/// [`Session::shutdown`] runs through the `&Session` that Emacs' user-pointer hands
/// back — there is never a `&mut` to be had.
pub struct Session {
    shared: Arc<Shared>,
    reader: Mutex<Option<JoinHandle<()>>>,
    wake: Mutex<Option<OwnedFd>>,
}

impl Session {
    /// Spawn `argv` and start reading. `wake` is a writable descriptor from
    /// `open_channel`, taken over by the session.
    pub fn spawn(
        argv: &[impl AsRef<OsStr>],
        env: &[(impl AsRef<str>, impl AsRef<str>)],
        size: Winsize,
        cwd: Option<&Path>,
        wake: RawFd,
        min_redisplay_interval: std::time::Duration,
        backlog_limit: usize,
    ) -> io::Result<Self> {
        // Take ownership of the wake descriptor and mark it close-on-exec *before*
        // forking. `open_channel` hands it over without FD_CLOEXEC (verified: children
        // showed it in /proc/self/fd), so a child would otherwise inherit the write end
        // of the pipe Emacs watches — free to poke our redisplay, and keeping the pipe
        // from ever reaching EOF.
        let wake = unsafe { OwnedFd::from_raw_fd(wake) };
        nix::fcntl::fcntl(
            wake.as_fd(),
            nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
        )
        .map_err(crate::compat::nixerr)?;

        let pty = Pty::spawn(argv, env, size, cwd)?;
        let mode = pty.mode().unwrap_or_default();
        let shared = Arc::new(Shared {
            pty,
            term: Mutex::new(Term::new(size.rows.into(), size.cols.into())),
            mode: AtomicU8::new(mode as u8),
            pending_resize: Mutex::new(None),
            dirty: AtomicBool::new(false),
            notified: AtomicBool::new(false),
            last_notified: Mutex::new(None),
            sync_until: Mutex::new(None),
            min_redisplay_interval,
            backlog_limit,
            shutdown: AtomicBool::new(false),
            quit: Quit::new()?,
            exited: Mutex::new(None),
        });

        let reader = std::thread::Builder::new()
            .name("cooked-reader".into())
            .spawn({
                let shared = Arc::clone(&shared);
                let wake = wake.try_clone()?;
                move || read_loop(&shared, wake.as_fd())
            })?;

        Ok(Self {
            shared,
            reader: Mutex::new(Some(reader)),
            wake: Mutex::new(Some(wake)),
        })
    }

    /// Tear the child down now and reap it, reporting whether this call was the one that
    /// did it. Idempotent, cheap after the first call, and safe from `Drop`.
    ///
    /// Emacs must never wait on someone else's `sleep 3600`, so the child gets SIGHUP, a
    /// short grace period, then SIGKILL. The escalation is not belt and braces: a child
    /// that ignores SIGHUP — `nohup`, `trap '' HUP`, a detached session leader — otherwise
    /// survives an explicit kill and is never reaped.
    pub fn shutdown(&self) -> bool {
        if self.shared.shutdown.swap(true, Ordering::SeqCst) {
            return false;
        }
        let _ = self.shared.pty.signal(libc::SIGHUP);
        self.shared.quit.wake();
        drop(self.wake.take().take());
        if let Some(reader) = self.reader.take().take() {
            let _ = reader.join();
        }

        // The reader is joined, so this sees its final word on the matter. `Some` means it
        // already reaped and the pid is no longer ours to signal.
        let mut exited = self.shared.exited.take();
        if exited.is_none() {
            *exited = self.shared.pty.reap(KILL_GRACE).or_else(|| {
                let _ = self.shared.pty.signal(libc::SIGKILL);
                self.shared.pty.reap(KILL_GRACE)
            });
        }
        true
    }

    /// Collect everything that changed, re-arming the wakeup.
    pub fn drain(&self) -> Update {
        self.shared.notified.store(false, Ordering::SeqCst);
        Update {
            delta: self.shared.term.take().drain(),
            mode: self.shared.load_mode(),
            exit: *self.shared.exited.take(),
        }
    }

    pub fn send(&self, bytes: &[u8]) -> io::Result<()> {
        self.shared.pty.write(bytes)
    }

    /// Forget that any of the top row's line is already in Emacs.
    ///
    /// Emacs holds the scrollback, so only Emacs knows when it has thrown it away.
    pub fn forget_history(&self) {
        self.shared.term.take().forget_history();
    }

    /// Resize the emulator and the pty, and keep asking until the child agrees.
    ///
    /// One attempt from here, deliberately: this runs on the thread holding the
    /// `emacs_env`, so it must never wait out a retry. But one attempt is not enough to
    /// be sure it took, for two separate reasons that both bite in the moments after
    /// `spawn` and both look like success from here:
    ///
    /// On macOS the ptmx master answers no winsize ioctl at all — `ENOTTY` — until some
    /// process has opened the slave, and the child is the process that does that.
    ///
    /// And everywhere, `child_exec` sets the initial winsize itself, on its own slave fd,
    /// after the fork. A resize applied to the master in that window succeeds and is then
    /// overwritten by the child's own initialisation, leaving the tty at the size `spawn`
    /// was given. Emacs walks into this every time it starts a session: the buffer has no
    /// window yet, so it spawns at the default 24x80 and `cooked--display` resizes
    /// milliseconds later — exactly the window in question.
    ///
    /// So the size is recorded as pending either way, and the reader thread re-applies it
    /// until the tty reads back with it. That converges within one poll tick, subsumes
    /// the `ENOTTY` case instead of special-casing it, and stops as soon as the two
    /// agree — so a child that later sets its own size is left alone.
    pub fn resize(&self, size: Winsize) -> io::Result<()> {
        self.shared
            .term
            .take()
            .resize(size.rows.into(), size.cols.into());
        *self.shared.pending_resize.take() = Some(size);
        match self.shared.pty.resize(size) {
            // Not ours to set yet; the reader thread keeps trying.
            Err(e) if e.raw_os_error() == Some(libc::ENOTTY) => Ok(()),
            result => result,
        }
    }

    /// Mark the whole screen damaged, so the next drain re-sends it.
    ///
    /// Emacs asks for this when its own idea of the screen region can no longer be
    /// trusted — a redisplay that signalled part-way through leaves the buffer holding
    /// some rows of a drain and not others, and no amount of further deltas repairs
    /// that, because a delta only describes what changed since.
    pub fn redraw(&self) {
        self.shared.term.take().touch_all();
    }

    /// Remove `count` grid rows starting at `first`, and repaint what moved.
    ///
    /// The one edit the grid accepts from Emacs. It goes through the emulator rather than
    /// Emacs deleting the buffer text itself for the same reason input does: the rows have
    /// one owner, and the drain that follows is the ordinary one.
    pub fn remove_rows(&self, first: usize, count: usize) {
        self.shared.term.take().remove_rows(first, count);
    }

    /// Drop the grid rows above the prompt; see [`Term::clear_to_prompt`].
    ///
    /// The other edit the grid accepts from Emacs, and the same bargain as
    /// [`Session::remove_rows`]: Emacs asks, the emulator moves the rows, and the drain
    /// that follows is the ordinary one.
    pub fn clear_to_prompt(&self) -> usize {
        self.shared.term.take().clear_to_prompt()
    }

    pub fn mode(&self) -> Mode {
        self.shared.load_mode()
    }

    pub fn pid(&self) -> Pid {
        self.shared.pty.pid()
    }

    pub fn signal(&self, sig: i32) -> io::Result<()> {
        self.shared.pty.signal(sig)
    }

    pub fn job_control(&self) -> io::Result<JobControl> {
        self.shared.pty.job_control()
    }

    pub fn alive(&self) -> bool {
        self.shared.exited.take().is_none()
    }

    /// The last non-blank line — the prompt text for a [`Mode::Secret`] read.
    pub fn trailing_text(&self) -> Option<String> {
        self.shared.term.take().trailing_text()
    }

    pub fn bracketed_paste(&self) -> bool {
        self.shared.term.take().bracketed_paste()
    }

    pub fn focus_events(&self) -> bool {
        self.shared.term.take().focus_events()
    }

    pub fn alt_scroll(&self) -> bool {
        self.shared.term.take().alt_scroll()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // Normally a no-op: `cooked--kill` runs from `kill-buffer-hook`, so by the time
        // the garbage collector finalises the handle there is nothing left to do. This is
        // the backstop for a session nobody killed explicitly.
        self.shutdown();
    }
}

/// How long the reader thread may block in `poll` before its next tick.
///
/// Ordinarily this is [`POLL_TIMEOUT_MS`] — plenty coarse, since real pty data wakes
/// `poll` immediately regardless of the timeout, and nothing else queued behind it
/// (`quit`, a stashed resize, a termios change) needs finer granularity. But when
/// `flush_pending` has already deferred a notification to `min_redisplay_interval`'s
/// throttle and the child then falls quiet, nothing else will wake the loop before that
/// window elapses — so waiting out the rest of `POLL_TIMEOUT_MS` instead adds up to a
/// hundred extra milliseconds onto the tail of every burst of output. Invisible on a
/// spinner, which is what the throttle exists for; felt as a stutter on the last frame of
/// output a mouse wheel just asked a full-screen program to draw. Shortening the poll to
/// exactly that remaining window, only while it applies, retires the notification at
/// `min_redisplay_interval`'s own cadence instead.
fn poll_timeout(shared: &Shared) -> PollTimeout {
    if shared.notified.load(Ordering::SeqCst) || !shared.dirty.load(Ordering::SeqCst) {
        return PollTimeout::from(POLL_TIMEOUT_MS);
    }
    let last = *shared.last_notified.take();
    let remaining = last
        .map(|t| shared.min_redisplay_interval.saturating_sub(t.elapsed()))
        .unwrap_or(std::time::Duration::ZERO);
    // A frame held by DEC mode 2026 keeps `dirty` set with nothing to flush, so the
    // throttle's own remainder is typically zero — polling on that would spin this thread
    // hot for the length of every frame. Taking the later of the two deadlines both fixes
    // that and retires the sync timeout at the timeout rather than up to a poll late.
    let remaining = remaining.max(sync_remaining(shared).unwrap_or_default());
    PollTimeout::try_from(remaining).unwrap_or(PollTimeout::from(POLL_TIMEOUT_MS))
}

fn read_loop(shared: &Arc<Shared>, wake: BorrowedFd<'_>) {
    block_sigpipe();
    let mut buf = vec![0u8; READ_CHUNK];

    while !shared.shutdown.load(Ordering::SeqCst) {
        let mut fds = [
            PollFd::new(shared.pty.as_fd(), PollFlags::POLLIN),
            PollFd::new(shared.quit.read.as_fd(), PollFlags::POLLIN),
        ];
        match poll(&mut fds, poll_timeout(shared)) {
            Err(nix::errno::Errno::EINTR) => continue,
            Err(_) => break,
            Ok(_) => {}
        }
        let quit = fds[1].revents().is_some_and(|r| !r.is_empty());
        let ready = fds[0].revents().is_some_and(|r| !r.is_empty());
        // Teardown asked us to stop; do not touch the pty on the way out.
        if quit {
            return;
        }

        // Sampled rather than pushed: Linux does not report ICANON/ECHO changes. The poll
        // timeout bounds the latency, and an unchanged mode costs nothing.
        if sample_mode(shared) {
            announce(shared, wake);
        }

        // A `resize` that arrived before the child opened its slave (see `Session::resize`)
        // is retried here, on the same cadence as `sample_mode` above and for the same
        // reason: this transient clears within microseconds of `spawn` returning, so the
        // next tick of a loop that is already running is enough — no dedicated wait needed.
        apply_pending_resize(shared);

        // Retries a notification `min_redisplay_interval` throttled earlier. Unconditional
        // so a quiet period still gets the last bit of output flushed within one more poll
        // cycle, rather than waiting on the next read that may never come.
        flush_pending(shared, wake);

        if !ready {
            continue;
        }

        // Backpressure: with a full backlog, leave the bytes in the pty. Its buffer
        // fills and the child blocks in `write`, so output waits instead of being
        // dropped or piling up in memory faster than Emacs can render it.
        if shared.term.take().backlog() >= shared.backlog_limit {
            // A child that filled the backlog inside one frame has forfeited atomicity:
            // holding the wakeup here would deadlock the backlog against its own blocked
            // write, waiting on a frame it cannot finish because we are not reading.
            *shared.sync_until.take() = None;
            announce(shared, wake);
            std::thread::sleep(std::time::Duration::from_millis(2));
            continue;
        }

        match shared.pty.read(&mut buf) {
            Ok([]) => return finish(shared, wake, Ended::ChildGone),
            Ok(data) => {
                shared.term.take().feed(data);
                // A child that changes mode almost always writes at the same moment, so
                // re-sampling here is what makes the common case feel instantaneous.
                sample_mode(shared);
                refresh_sync(shared);
                announce(shared, wake);
            }
            // EIO is how Linux reports the last slave closing.
            Err(e) if e.raw_os_error() == Some(libc::EIO) => {
                return finish(shared, wake, Ended::ChildGone);
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return finish(shared, wake, Ended::Aborted),
        }
    }

    finish(shared, wake, Ended::Aborted);
}

enum Ended {
    /// The pty reported EOF, so the child is on its way out and can be reaped.
    ChildGone,
    /// We are tearing down; the child may well still be running.
    Aborted,
}

fn finish(shared: &Arc<Shared>, wake: BorrowedFd<'_>, why: Ended) {
    let patience = match why {
        Ended::ChildGone => REAP_PATIENCE,
        Ended::Aborted => std::time::Duration::ZERO,
    };
    let Some(status) = shared.pty.reap(patience) else {
        return;
    };
    *shared.exited.take() = Some(status);
    shared.notified.store(false, Ordering::SeqCst);
    notify(shared, wake);
}

/// A write to the wake pipe races Emacs closing its read end. SIGPIPE is delivered to the
/// writing thread, so blocking it here turns that race into a harmless `EPIPE` instead of
/// killing Emacs.
fn block_sigpipe() {
    let mut set = SigSet::empty();
    set.add(Signal::SIGPIPE);
    let _ = set.thread_block();
}

/// Re-read the child's termios, reporting whether it changed.
fn sample_mode(shared: &Arc<Shared>) -> bool {
    shared.pty.mode().is_ok_and(|mode| {
        let changed = mode != shared.load_mode();
        shared.store_mode(mode);
        changed
    })
}

/// Drive the pty to the size `Session::resize` last asked for.
///
/// Cleared only once the tty *reads back* with that size, not merely once the ioctl
/// succeeds: the child's own initialisation can overwrite a successful set, and the
/// difference between those two is invisible without reading it back. See
/// `Session::resize`.
fn apply_pending_resize(shared: &Arc<Shared>) {
    let mut pending = shared.pending_resize.take();
    let Some(size) = *pending else { return };
    if shared.pty.winsize().is_ok_and(|current| current == size) {
        *pending = None;
        return;
    }
    let _ = shared.pty.resize(size);
}

/// Unconditionally sends the wake byte if none is already in flight.
///
/// Used directly only by `finish`: a session ending must reach Emacs right away, and
/// `min_redisplay_interval` is about redraw cadence, not about delaying "the child is
/// gone." Everywhere else goes through `announce`.
fn notify(shared: &Arc<Shared>, wake: BorrowedFd<'_>) {
    if shared.notified.swap(true, Ordering::SeqCst) {
        return;
    }
    // A failed write means Emacs closed its read end, so there is nobody left to tell.
    if nix::unistd::write(wake, b"\x01").is_err() {
        shared.shutdown.store(true, Ordering::SeqCst);
    }
}

/// Copy the emulator's synchronized-output deadline where the notify path can see it.
fn refresh_sync(shared: &Arc<Shared>) {
    let deadline = shared.term.take().sync_deadline();
    *shared.sync_until.take() = deadline;
}

/// How much longer the child may suppress a redisplay, or `None` if it may not.
fn sync_remaining(shared: &Shared) -> Option<std::time::Duration> {
    let deadline = *shared.sync_until.take();
    deadline.and_then(|t| t.checked_duration_since(std::time::Instant::now()))
}

/// Marks output or a mode change as pending and flushes it if `min_redisplay_interval`
/// allows. See `Shared`'s docs on `dirty` and `min_redisplay_interval`.
fn announce(shared: &Arc<Shared>, wake: BorrowedFd<'_>) {
    shared.dirty.store(true, Ordering::SeqCst);
    flush_pending(shared, wake);
}

/// Sends the wake byte if something is pending, nothing is already in flight, and
/// `min_redisplay_interval` has elapsed since the last send.
fn flush_pending(shared: &Arc<Shared>, wake: BorrowedFd<'_>) {
    if shared.notified.load(Ordering::SeqCst) || !shared.dirty.load(Ordering::SeqCst) {
        return;
    }
    // Before `dirty` is cleared, deliberately: leaving it set is what hands the frame to
    // the retry machinery, so the held output is drawn the moment the frame ends or the
    // timeout expires rather than waiting on the child's next write.
    if sync_remaining(shared).is_some() {
        return;
    }
    let mut last = shared.last_notified.take();
    if last.is_some_and(|t| t.elapsed() < shared.min_redisplay_interval) {
        return;
    }
    *last = Some(std::time::Instant::now());
    drop(last);
    shared.dirty.store(false, Ordering::SeqCst);
    notify(shared, wake);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emu::{self, Event};
    use nix::errno::Errno;
    use std::time::{Duration, Instant};

    /// `kill(pid, 0)` only probes for existence. ESRCH means the pid is gone for good.
    fn alive(pid: i32) -> nix::Result<()> {
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None)
    }

    /// Close-on-exec, because these tests fork children concurrently: a plain `pipe`
    /// leaves the read end inheritable, and `the_child_inherits_only_stdio` then sees
    /// *this* fd surviving someone else's exec and reports a leak that is the test
    /// harness' own.
    fn pipe() -> (OwnedFd, OwnedFd) {
        nix::unistd::pipe2(nix::fcntl::OFlag::O_CLOEXEC).expect("pipe")
    }

    fn session(argv: &[&str]) -> (Session, OwnedFd) {
        session_with_backlog(argv, emu::BACKLOG_HIGH_WATER)
    }

    fn session_with_backlog(argv: &[&str], backlog_limit: usize) -> (Session, OwnedFd) {
        let (read, write) = pipe();
        let size = Winsize { rows: 24, cols: 80 };
        let fd = std::os::fd::IntoRawFd::into_raw_fd(write);
        (
            Session::spawn(
                argv,
                &[("TERM", "xterm-256color")],
                size,
                None,
                fd,
                Duration::from_millis(8),
                backlog_limit,
            )
            .expect("spawn"),
            read,
        )
    }

    fn wait_for(session: &Session, mut done: impl FnMut(&Update) -> bool) -> Update {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut merged = session.drain();
        while Instant::now() < deadline {
            if done(&merged) {
                return merged;
            }
            std::thread::sleep(Duration::from_millis(20));
            let next = session.drain();
            merged.delta.rows.extend(next.delta.rows);
            merged.delta.scrolled.extend(next.delta.scrolled);
            merged.delta.events.extend(next.delta.events);
            merged.mode = next.mode;
            merged.exit = next.exit;
        }
        panic!("timed out waiting on session");
    }

    fn rendered(update: &Update) -> String {
        update
            .delta
            .rows
            .iter()
            .flat_map(|(_, runs)| runs.iter().map(|r| r.text.clone()))
            .collect()
    }

    /// Backpressure must throttle the child, never drop its output. A limit of 1 keeps the
    /// reader stalled almost continuously, which is the harshest version of that promise.
    #[test]
    fn a_tiny_backlog_limit_throttles_without_losing_output() {
        const LINES: usize = 200;
        // The trailing blank lines push the numbered ones off the live screen, so every
        // line this asserts on has actually travelled through the backlog.
        let (session, _read) = session_with_backlog(
            &[
                "/bin/sh",
                "-c",
                &format!("seq 1 {LINES}; i=0; while [ $i -lt 40 ]; do echo; i=$((i+1)); done"),
            ],
            1,
        );

        let mut collected: Vec<String> = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            let update = session.drain();
            collected.extend(update.delta.scrolled.iter().map(|line| {
                line.runs
                    .iter()
                    .map(|r| r.text.as_str())
                    .collect::<String>()
            }));
            if collected.len() >= LINES {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }

        let numbers: Vec<&str> = collected
            .iter()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect();
        assert_eq!(
            numbers.len(),
            LINES,
            "backpressure dropped lines instead of stalling the child"
        );
        assert_eq!(numbers[0], "1");
        assert_eq!(numbers[LINES - 1], LINES.to_string());
    }

    #[test]
    fn output_reaches_the_grid_through_the_reader_thread() {
        let (session, _read) = session(&["/bin/sh", "-c", "printf hello"]);
        let update = wait_for(&session, |u| rendered(u).contains("hello"));
        assert!(rendered(&update).contains("hello"));
    }

    #[test]
    fn the_wake_pipe_is_poked_on_output() {
        let (session, read) = session(&["/bin/sh", "-c", "printf hi"]);
        let mut byte = [0u8; 1];
        assert_eq!(nix::unistd::read(read.as_fd(), &mut byte), Ok(1));
        assert_eq!(byte[0], 1);
        drop(session);
    }

    #[test]
    fn synchronized_output_holds_the_wakeup_until_the_frame_ends() {
        // BSU, then output, then a pause well inside the 150ms cap: nothing must wake
        // Emacs, because the child has said the frame is not worth drawing yet.
        let (session, read) = session(&[
            "/bin/sh",
            "-c",
            "printf '\x1b[?2026h'; printf 'half a frame'; sleep 5",
        ]);
        std::thread::sleep(Duration::from_millis(60));

        let mut buf = [0u8; 256];
        nix::fcntl::fcntl(
            read.as_fd(),
            nix::fcntl::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
        )
        .expect("nonblock");
        assert_eq!(
            nix::unistd::read(read.as_fd(), &mut buf).err(),
            Some(Errno::EAGAIN),
            "a frame in progress must not wake Emacs"
        );
        drop(session);
    }

    #[test]
    fn an_unterminated_frame_is_drawn_when_the_timeout_expires() {
        // BSU and then silence — the child died mid-frame, or simply never finished it.
        // The buffer must not stay stale for longer than the cap.
        let (session, read) = session(&[
            "/bin/sh",
            "-c",
            "printf '\x1b[?2026h'; printf 'half a frame'; sleep 5",
        ]);
        std::thread::sleep(emu::SYNC_TIMEOUT + Duration::from_millis(120));

        let mut buf = [0u8; 256];
        assert_eq!(
            nix::unistd::read(read.as_fd(), &mut buf).expect("read"),
            1,
            "the held frame must be drawn once the cap expires"
        );
        drop(session);
    }

    #[test]
    fn wakeups_coalesce_into_one_byte_per_drain() {
        let (session, read) = session(&[
            "/bin/sh",
            "-c",
            "for i in $(seq 200); do printf 'line %s\\n' $i; done; sleep 5",
        ]);
        std::thread::sleep(Duration::from_millis(300));

        let mut buf = [0u8; 256];
        let n = nix::unistd::read(read.as_fd(), &mut buf).expect("read");
        assert_eq!(n, 1, "200 lines of output must not produce 200 wakeups");
        drop(session);
    }

    /// A write that lands inside `min_redisplay_interval' of the previous one gets its
    /// notification throttled; `poll_timeout` exists so the retry happens at that
    /// interval's own cadence rather than waiting out the coarser `POLL_TIMEOUT_MS`
    /// (100ms). `session`/`session_with_backlog` fix the interval at 8ms for every test.
    ///
    /// Reads the wake pipe directly rather than going through `drain`, which reflects
    /// `Term`'s live state regardless of whether a wakeup was ever sent for it — exactly
    /// the property that makes throttling safe (see `min_redisplay_interval`'s docs) but
    /// also the reason `drain` cannot observe a throttled *notification* being retried
    /// late. The wake pipe is the one thing actually gated by `poll_timeout`.
    #[test]
    fn a_throttled_notification_is_retried_near_min_redisplay_interval_not_poll_timeout() {
        let (session, read) = session(&[
            "/bin/sh",
            "-c",
            "printf 'first\n'; sleep 0.003; printf 'second\n'; sleep 5",
        ]);
        let mut byte = [0u8; 1];
        nix::unistd::read(read.as_fd(), &mut byte).expect("first wake");
        // Clears `notified`, the same way Emacs' filter does before draining — without
        // this the second wake has nothing to do with the second write; it would just be
        // the first notification's own byte, since none can follow while it is in flight.
        session.drain();

        let start = Instant::now();
        nix::unistd::read(read.as_fd(), &mut byte).expect("second wake");
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_millis(50),
            "took {elapsed:?} for a throttled notification to retry; \
             expected well under POLL_TIMEOUT_MS (100ms)"
        );
    }

    #[test]
    fn input_round_trips_through_the_pty() {
        let (session, _read) = session(&["/bin/cat"]);
        session.send(b"ping\n").expect("send");
        let update = wait_for(&session, |u| rendered(u).contains("ping"));
        assert!(rendered(&update).contains("ping"));
    }

    #[test]
    fn mode_transitions_are_observed() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 0.2; stty -echo; sleep 5"]);
        assert_eq!(session.mode(), Mode::Cooked);
        let update = wait_for(&session, |u| u.mode == Mode::Secret);
        assert_eq!(update.mode, Mode::Secret);
    }

    /// The pty master is closed by `Pty::spawn`, but the wake descriptor is only ours
    /// once `Session::spawn` has it — and `open_channel` hands it over without
    /// FD_CLOEXEC, so marking it has to happen before the fork, not after.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_child_inherits_neither_the_master_nor_the_wake_pipe() {
        // Not close-on-exec, because that is exactly what `open_channel` hands over:
        // marking it before the fork is the thing under test. The read end is, so it
        // stands in for the copy Emacs keeps rather than adding noise of its own.
        let read = crate::compat::cloexec_pipe().expect("pipe");
        let wake = std::os::fd::IntoRawFd::into_raw_fd(read.1);
        // The shim marks both ends, so clear it again on the write end — otherwise the
        // test would pass whether or not `Session::spawn` does its job.
        nix::fcntl::fcntl(
            unsafe { BorrowedFd::borrow_raw(wake) },
            nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::empty()),
        )
        .expect("clear cloexec");
        let ours = std::fs::read_link(format!("/proc/self/fd/{wake}")).expect("link");

        // The child greps for it itself: the cargo harness has plenty of unrelated
        // pipes open, and a rendered `ls -l` wraps, which would split the inode across
        // rows and make matching here unreliable.
        let script = format!(
            "if ls -l /proc/self/fd | grep -qF '{}'; then echo WAKE-LEAKED; fi; \
             if ls -l /proc/self/fd | grep -qF ptmx; then echo PTMX-LEAKED; fi; echo checked",
            ours.to_string_lossy()
        );
        let session = Session::spawn(
            &["/bin/sh", "-c", &script],
            &[("PATH", "/usr/bin:/bin")],
            Winsize { rows: 24, cols: 80 },
            None,
            wake,
            Duration::from_millis(8),
            emu::BACKLOG_HIGH_WATER,
        )
        .expect("spawn");

        let update = wait_for(&session, |u| rendered(u).contains("checked"));
        let text = rendered(&update);
        assert!(
            !text.contains("WAKE-LEAKED"),
            "the wake pipe reached the child:\n{text}"
        );
        assert!(
            !text.contains("PTMX-LEAKED"),
            "the pty master reached the child:\n{text}"
        );
        drop(read.0);
    }

    #[test]
    fn shutdown_is_idempotent_and_kills_the_child() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 300"]);
        let pid = session.pid().get();
        assert!(
            session.shutdown(),
            "the first call should be the one that tears down"
        );
        assert!(!session.shutdown(), "a second call must be a no-op");
        assert!(!session.alive());
        assert_eq!(
            alive(pid),
            Err(Errno::ESRCH),
            "the child outlived an explicit shutdown"
        );
    }

    #[test]
    fn shutdown_survives_a_child_that_ignores_sighup() {
        let (session, _read) = session(&["/bin/sh", "-c", "trap '' HUP; sleep 300"]);
        let pid = session.pid().get();
        std::thread::sleep(Duration::from_millis(150));
        assert!(session.shutdown());
        assert_eq!(
            alive(pid),
            Err(Errno::ESRCH),
            "SIGHUP alone is not enough here"
        );
    }

    #[test]
    fn shutdown_returns_promptly() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 300"]);
        let start = Instant::now();
        session.shutdown();
        // Without the quit pipe this waits out the reader's poll timeout every time.
        assert!(
            start.elapsed() < Duration::from_millis(150),
            "took {:?}",
            start.elapsed()
        );
    }

    #[test]
    fn exit_status_is_reported() {
        let (session, _read) = session(&["/bin/sh", "-c", "exit 7"]);
        let update = wait_for(&session, |u| u.exit.is_some());
        assert_eq!(update.exit, Some(7));
        assert!(!session.alive());
    }

    #[test]
    fn osc_133_survives_the_round_trip() {
        let (session, _read) =
            session(&["/bin/sh", "-c", r"printf '\033]133;A\007$ \033]133;B\007'"]);
        // `matches!` rather than equality: the marks carry an anchor, and where the
        // prompt lands is this test's least interesting property.
        let update = wait_for(&session, |u| {
            u.delta
                .events
                .iter()
                .any(|e| matches!(e, Event::PromptStart(_)))
        });
        assert!(
            update
                .delta
                .events
                .iter()
                .any(|e| matches!(e, Event::PromptEnd(_)))
        );
    }

    #[test]
    fn resize_reaches_the_child() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 0.3; stty size"]);
        session
            .resize(Winsize { rows: 12, cols: 40 })
            .expect("resize");
        let update = wait_for(&session, |u| rendered(u).contains("12 40"));
        assert!(rendered(&update).contains("12 40"));
    }
}
