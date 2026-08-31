//! A running child: pty, emulator, and the reader thread that couples them to Emacs.
//!
//! Emacs' module functions may only be called from the thread holding an `emacs_env`, so
//! the reader never touches Lisp. It parses into the shared [`Term`] and pokes a pipe
//! descriptor obtained from `open_channel`; Emacs' filter then drains on the main thread.

use crate::emu::{Delta, Term};
use crate::error::Result;
use crate::pty::{AtomicMode, JobControl, Mode, Pid, Pty, Winsize};
use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{SigSet, Signal};
use std::ffi::OsStr;
use std::os::fd::{AsFd, OwnedFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
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
/// So take every lock in this file through `held`, and never through
/// `.lock().is_ok_and(..)` or `.lock().ok()?`: those answer "no" instead of recovering,
/// which after a single poisoning leaves `drain` working while `bracketed_paste` reports
/// false forever and `alive` reports the session dead. Stating the policy in one place
/// is what this trait is for.
///
/// Named `held` rather than `take` because `Option::take` is the most famous method of
/// that name, and `self.reader.held().take()` reads as one meaning per call rather than
/// two in one expression.
trait LockExt<T> {
    fn held(&self) -> MutexGuard<'_, T>;
}

impl<T> LockExt<T> for Mutex<T> {
    fn held(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

const READ_CHUNK: usize = 64 * 1024;
/// How long the reader may sit in `poll` with nothing else to wait for.
///
/// This is not a frame rate and nothing about redisplay is keyed on it: real pty data
/// wakes `poll` the moment it arrives, whatever this says. It bounds exactly one thing —
/// how stale the termios sample may be while the child is silent — because Linux reports
/// no `ICANON`/`ECHO` change to the master. See `Pty::mode`.
///
/// Left at 100ms, and the reasoning is worth keeping because the obvious change here is
/// a trap that has already been measured.
///
/// The tick used to carry two jobs: noticing a silent mode change, *and* standing between
/// a `tcsetattr` and a password typed into an Emacs-owned line. The second is what made
/// it unbudgeable, since every millisecond added widened the window in which a secret
/// could be rendered into the buffer. [`Session::sample_mode`] took that job away — the
/// input path reads the tty itself now, so no keystroke is interpreted under a stale mode
/// at any tick length — which leaves this bounding only how soon a *silent* mode change
/// is noticed by nobody in particular.
///
/// That looks like a free knob and is not. Raising it to 250ms was tried and measured: it
/// takes an idle session from ~10 wakeups/sec to ~4, which is a real power win, and it
/// costs exactly the case the tick exists for. A child that turns echo off and prints
/// nothing can only ever be noticed here, so the detection latency for it rises with the
/// interval — far enough that
/// `cooked-a-child-that-exits-while-suspended-hands-the-buffer-back` and
/// `cooked-evil-normal-state-does-not-outlive-the-child`, whose children go silently raw
/// and then exit 200ms later, stop observing the mode at all.
///
/// So the trade is live and one-sided in a way only the user can price: 2.5x fewer idle
/// wakeups against a silent `read -s` taking a quarter second to raise its prompt. It is
/// one constant, and it should be changed deliberately rather than because it looks
/// harmless. [`RESAMPLE_DELAY`] is the half of that win which costs nothing, and is
/// taken.
const POLL_TIMEOUT_MS: u8 = 100;

/// How long after a burst of output to take one extra termios sample.
///
/// The common secret read does not arrive silently: `read -s -p`, `getpass` and `sudo`
/// all write their prompt and change the tty within a fraction of a millisecond of each
/// other, in that order. Measured, on the shells this was written against, at ~0.03ms
/// apart — which is why `cooked-secret-debounce` on the Lisp side is 0.03s and says the
/// same thing from the other end: "programs differ on whether they clear ECHO before or
/// after printing the prompt."
///
/// So the sample taken immediately after a read is a coin flip, and the one after that is
/// [`POLL_TIMEOUT_MS`] away. Arming a single extra sample in the wake of output catches
/// the whole ordered-after case promptly without putting the base tick back: output is
/// what makes it worth asking again, so a session with no output arms nothing and pays
/// nothing.
const RESAMPLE_DELAY: std::time::Duration = std::time::Duration::from_millis(50);
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

/// Telling Emacs there is something to look at, and how often it is willing to hear it.
///
/// One type rather than five fields on [`Shared`] and four free functions beside it:
/// these pieces are only ever touched together, and gathering them gives the wake
/// descriptor -- which is what they are all for -- an owner, so it need not be threaded
/// as a `BorrowedFd` parameter through every signature that might eventually flush.
///
/// `last` and `sync_until` share one mutex because `flush` reads both: as two mutexes it
/// took them in sequence, and `poll_timeout` took both again on every tick.
struct Notifier {
    /// The write end of Emacs' wake pipe, `None` once teardown has closed it.
    wake: Mutex<Option<OwnedFd>>,
    /// Set when output or a mode change has not yet been announced over the wake pipe;
    /// cleared once a flush actually writes. Distinct from `notified`: this tracks whether
    /// there is anything new to say, that one tracks whether we have already said it and
    /// Emacs has not yet drained.
    dirty: AtomicBool,
    /// Set when a wakeup byte is in flight; cleared by the drain, so a burst of output
    /// costs one write and one Lisp callback rather than thousands.
    notified: AtomicBool,
    state: Mutex<NotifyState>,
    /// Floor on how often the wake pipe is written to, regardless of how fast output
    /// arrives. Without one, a program that rewrites the same line rapidly — a spinner, a
    /// progress meter — drives one full Emacs redisplay per write, which is a lot more
    /// redraws than any of them are actually meant to be seen at and shows up as flicker.
    /// No matching ceiling is needed the way `eat-maximum-latency` provides one: `Term`
    /// always holds the latest state regardless of whether a wakeup was sent for it, and
    /// [`Notifier::flush`] is retried every reader-thread tick — see
    /// [`Notifier::poll_wait`], which shortens that tick to this interval's own
    /// remaining window rather than leaving a throttled notification to wait out the
    /// coarser `POLL_TIMEOUT_MS`.
    min_interval: std::time::Duration,
}

#[derive(Default)]
struct NotifyState {
    /// When the wake pipe was last actually written to, for `min_interval`.
    last: Option<std::time::Instant>,
    /// While set and unexpired, the child is mid-frame under DEC mode 2026 and has asked
    /// not to be drawn yet. Refreshed from `Term` under the lock the reader already holds,
    /// so no path takes an extra one.
    sync_until: Option<std::time::Instant>,
}

impl Notifier {
    fn new(wake: OwnedFd, min_interval: std::time::Duration) -> Self {
        Self {
            wake: Mutex::new(Some(wake)),
            dirty: AtomicBool::new(false),
            notified: AtomicBool::new(false),
            state: Mutex::new(NotifyState::default()),
            min_interval,
        }
    }

    /// Unconditionally send the wake byte if none is already in flight.
    ///
    /// Returns whether Emacs is still listening: a failed write means it closed its read
    /// end, and the caller's business is to shut down rather than to retry.
    fn notify(&self) -> bool {
        if self.notified.swap(true, Ordering::SeqCst) {
            return true;
        }
        match &*self.wake.held() {
            Some(wake) => nix::unistd::write(wake.as_fd(), b"\x01").is_ok(),
            None => false,
        }
    }

    /// Mark output or a mode change pending, and flush it if the throttle allows.
    fn announce(&self) -> bool {
        self.dirty.store(true, Ordering::SeqCst);
        self.flush()
    }

    /// Send the wake byte if something is pending, nothing is already in flight, and
    /// `min_interval` has elapsed since the last send.
    fn flush(&self) -> bool {
        if self.notified.load(Ordering::SeqCst) || !self.dirty.load(Ordering::SeqCst) {
            return true;
        }
        let mut state = self.state.held();
        // Before `dirty` is cleared, deliberately: leaving it set is what hands the frame
        // to the retry machinery, so the held output is drawn the moment the frame ends or
        // the timeout expires rather than waiting on the child's next write.
        if remaining(state.sync_until).is_some() {
            return true;
        }
        if state.last.is_some_and(|t| t.elapsed() < self.min_interval) {
            return true;
        }
        state.last = Some(std::time::Instant::now());
        drop(state);
        self.dirty.store(false, Ordering::SeqCst);
        self.notify()
    }

    /// Emacs has drained, so the next change is worth another byte.
    ///
    /// Returns whether a throttled notification is still waiting. Flushing here retires
    /// the ordinary case, where the drain lands after `min_interval` has already elapsed.
    /// A drain that lands inside the window leaves the retry to the reader thread — which
    /// computed its [`Self::poll_timeout`] while the previous wakeup was still in flight,
    /// and so is asleep for the whole of `POLL_TIMEOUT_MS` rather than for the few
    /// milliseconds this notification actually has left to wait. That is the caller's cue
    /// to interrupt the poll so the timeout is computed again.
    fn drained(&self) -> bool {
        self.notified.store(false, Ordering::SeqCst);
        self.flush();
        self.dirty.load(Ordering::SeqCst) && !self.notified.load(Ordering::SeqCst)
    }

    /// Copy the emulator's synchronized-output deadline where the notify path can see it.
    fn set_sync(&self, deadline: Option<std::time::Instant>) {
        self.state.held().sync_until = deadline;
    }

    /// How long the reader thread may sleep in `poll`.
    ///
    /// Ordinarily [`POLL_TIMEOUT_MS`] — plenty coarse, since real pty data wakes `poll`
    /// immediately regardless of the timeout, and nothing else queued behind it (teardown,
    /// a stashed resize, a termios change) needs finer granularity. But when [`Self::flush`]
    /// has already deferred a notification to `min_interval`'s throttle and the child then
    /// falls quiet, nothing else will wake the loop before that window elapses — so waiting
    /// out the rest of `POLL_TIMEOUT_MS` instead adds up to a hundred extra milliseconds
    /// onto the tail of every burst of output. Invisible on a spinner, which is what the
    /// throttle exists for; felt as a stutter on the last frame of output a mouse wheel
    /// just asked a full-screen program to draw. Shortening the poll to exactly that
    /// remaining window, only while it applies, retires the notification at `min_interval`'s
    /// own cadence instead.
    fn poll_wait(&self) -> std::time::Duration {
        if self.notified.load(Ordering::SeqCst) || !self.dirty.load(Ordering::SeqCst) {
            return std::time::Duration::from_millis(u64::from(POLL_TIMEOUT_MS));
        }
        // One lock for both halves; as two fields it was two, on every tick.
        let state = self.state.held();
        let throttle = state
            .last
            .map(|t| self.min_interval.saturating_sub(t.elapsed()))
            .unwrap_or_default();
        // A frame held by DEC mode 2026 keeps `dirty` set with nothing to flush, so the
        // throttle's own remainder is typically zero — polling on that would spin this
        // thread hot for the length of every frame. Taking the later of the two deadlines
        // both fixes that and retires the sync timeout at the timeout rather than up to a
        // poll late.
        let wait = throttle.max(remaining(state.sync_until).unwrap_or_default());
        drop(state);
        wait
    }

    /// Close the wake pipe, so Emacs' read end sees EOF.
    fn close(&self) {
        drop(self.wake.held().take());
    }
}

/// How much of a deadline is left, or `None` if it has passed or was never set.
fn remaining(deadline: Option<std::time::Instant>) -> Option<std::time::Duration> {
    deadline.and_then(|t| t.checked_duration_since(std::time::Instant::now()))
}

struct Shared {
    pty: Pty,
    term: Mutex<Term>,
    mode: AtomicMode,
    /// A size the child is not yet known to have, for the reader thread to keep applying
    /// until it sticks. `None` once the tty agrees. See `Session::resize`.
    pending_resize: Mutex<Option<Winsize>>,
    /// Everything to do with telling Emacs there is something to draw; see [`Notifier`].
    notifier: Notifier,
    /// When to take one extra termios sample in the wake of output; see
    /// [`RESAMPLE_DELAY`]. `None` whenever no burst is outstanding, which is most of the
    /// time and is what keeps an idle session from arming anything at all.
    resample_at: Mutex<Option<std::time::Instant>>,
    /// Pending items — scrolled-off lines plus undelivered events — at which the reader
    /// stops pulling from the pty and lets the child block. Raising it does not make
    /// rendering faster, since throughput is bounded by Emacs rather than by this queue;
    /// it lets a child run ahead and exit sooner instead of blocking in `write`, at the
    /// cost of memory and a larger worst-case redisplay when one drain finally lands.
    /// Tuned together with `min_redisplay_interval`: a longer interval leaves more to
    /// accumulate between drains, so this fills sooner.
    backlog_limit: usize,
    shutdown: AtomicBool,
    interrupt: Interrupt,
    exited: Mutex<Option<i32>>,
}

/// A self-pipe the reader polls alongside the pty, so the two things that can happen
/// while the child is quiet do not have to wait out the poll timeout.
///
/// Teardown is one: without this, every kill blocks Emacs for up to [`POLL_TIMEOUT_MS`],
/// which is the difference between closing a buffer feeling instant and feeling like a
/// stutter. A drain that leaves a throttled notification behind is the other; see
/// [`Notifier::drained`]. Neither carries a payload — [`Shared::shutdown`] tells the two
/// apart, and it is set before the interrupt is raised — so the reader need only empty the
/// pipe and look at the flag.
struct Interrupt {
    read: OwnedFd,
    write: OwnedFd,
}

impl Interrupt {
    fn new() -> Result<Self> {
        // O_CLOEXEC, so this does not reintroduce the inherited fd `Pty::spawn` just went
        // to the trouble of closing. O_NONBLOCK so a raise can never park its caller behind
        // a full pipe, and so `clear` cannot block on a byte another raise got to first.
        let (read, write) = crate::platform::cloexec_pipe()?;
        Ok(Self { read, write })
    }

    fn raise(&self) {
        let _ = nix::unistd::write(self.write.as_fd(), b"q");
    }

    /// Empty the pipe, so the next poll blocks again rather than returning at once.
    fn clear(&self) {
        // A raise while this runs simply arrives on the next poll; nothing is lost, since
        // what the reader does on waking is unconditional and idempotent either way.
        let mut buf = [0u8; 64];
        while let Ok(1..) = nix::unistd::read(self.read.as_fd(), &mut buf) {}
    }
}

/// A live child, its emulator, and the reader thread coupling them to Emacs.
///
/// The owned resources sit behind mutexes rather than in plain `Option`s because
/// [`Session::shutdown`] runs through the `&Session` that Emacs' user-pointer hands
/// back — there is never a `&mut` to be had.
/// The tuning knobs [`Session::spawn`] takes, so they arrive named rather than as the
/// last two of seven positional parameters -- and so their defaults live in the [`Default`]
/// impl below, next to the fields they belong to, rather than at the call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Options {
    /// See [`Notifier::min_interval`].
    pub min_redisplay_interval: std::time::Duration,
    /// See [`Shared::backlog_limit`].
    pub backlog_limit: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            min_redisplay_interval: std::time::Duration::from_millis(8),
            backlog_limit: crate::emu::BACKLOG_HIGH_WATER,
        }
    }
}

pub struct Session {
    shared: Arc<Shared>,
    reader: Mutex<Option<JoinHandle<()>>>,
}

impl Session {
    /// Spawn `argv` and start reading. `wake` is a writable descriptor from
    /// `open_channel`, taken over by the session.
    pub fn spawn(
        argv: &[impl AsRef<OsStr>],
        env: &[(impl AsRef<str>, impl AsRef<str>)],
        size: Winsize,
        cwd: Option<&Path>,
        wake: OwnedFd,
        options: Options,
    ) -> Result<Self> {
        // Mark the wake descriptor close-on-exec *before* forking. `open_channel` hands it
        // over without FD_CLOEXEC (verified: children showed it in /proc/self/fd), so a
        // child would otherwise inherit the write end of the pipe Emacs watches — free to
        // poke our redisplay, and keeping the pipe from ever reaching EOF.
        nix::fcntl::fcntl(
            wake.as_fd(),
            nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
        )?;

        let pty = Pty::spawn(argv, env, size, cwd)?;
        let mode = pty.mode().unwrap_or_default();
        let shared = Arc::new(Shared {
            pty,
            term: Mutex::new(Term::new(size.rows.into(), size.cols.into())),
            mode: AtomicMode::new(mode),
            pending_resize: Mutex::new(None),
            notifier: Notifier::new(wake, options.min_redisplay_interval),
            resample_at: Mutex::new(None),
            backlog_limit: options.backlog_limit,
            shutdown: AtomicBool::new(false),
            interrupt: Interrupt::new()?,
            exited: Mutex::new(None),
        });

        let reader = std::thread::Builder::new()
            .name("cooked-reader".into())
            .spawn({
                let shared = Arc::clone(&shared);
                move || shared.read_loop()
            })?;

        Ok(Self {
            shared,
            reader: Mutex::new(Some(reader)),
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
        let _ = self.shared.pty.signal(Signal::SIGHUP);
        self.shared.interrupt.raise();
        self.shared.notifier.close();
        if let Some(reader) = self.reader.held().take() {
            let _ = reader.join();
        }

        // The reader is joined, so this sees its final word on the matter. `Some` means it
        // already reaped and the pid is no longer ours to signal.
        let mut exited = self.shared.exited.held();
        if exited.is_none() {
            *exited = self.shared.pty.reap(KILL_GRACE).or_else(|| {
                let _ = self.shared.pty.signal(Signal::SIGKILL);
                self.shared.pty.reap(KILL_GRACE)
            });
        }
        true
    }

    /// Collect everything that changed, re-arming the wakeup.
    pub fn drain(&self) -> Update {
        if self.shared.notifier.drained() {
            self.shared.interrupt.raise();
        }
        Update {
            delta: self.shared.term.held().drain(),
            mode: self.shared.mode.load(),
            exit: *self.shared.exited.held(),
        }
    }

    pub fn send(&self, bytes: &[u8]) -> Result<()> {
        self.shared.pty.write(bytes)
    }

    /// Forget that any of the top row's line is already in Emacs.
    ///
    /// Emacs holds the scrollback, so only Emacs knows when it has thrown it away.
    pub fn forget_history(&self) {
        self.shared.term.held().forget_history();
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
    pub fn resize(&self, size: Winsize) -> Result<()> {
        {
            let mut term = self.shared.term.held();
            term.resize(size.rows.into(), size.cols.into());
            // Reported together because they change together: a font change moves the
            // cell size and the row and column count in one event.
            term.set_cell_metrics(size.cell);
        }
        *self.shared.pending_resize.held() = Some(size);
        match self.shared.pty.resize(size) {
            // Not ours to set yet; the reader thread keeps trying.
            Err(e) if e.is(Errno::ENOTTY) => Ok(()),
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
        self.shared.term.held().touch_all();
    }

    /// Remove `count` grid rows starting at `first`, and repaint what moved.
    ///
    /// The one edit the grid accepts from Emacs. It goes through the emulator rather than
    /// Emacs deleting the buffer text itself for the same reason input does: the rows have
    /// one owner, and the drain that follows is the ordinary one.
    pub fn remove_rows(&self, first: usize, count: usize) {
        self.shared.term.held().remove_rows(first, count);
    }

    /// Drop the grid rows above the prompt; see [`Term::clear_to_prompt`].
    ///
    /// The other edit the grid accepts from Emacs, and the same bargain as
    /// [`Session::remove_rows`]: Emacs asks, the emulator moves the rows, and the drain
    /// that follows is the ordinary one.
    pub fn clear_to_prompt(&self) -> usize {
        self.shared.term.held().clear_to_prompt()
    }

    pub fn mode(&self) -> Mode {
        self.shared.mode.load()
    }

    /// Re-read the child's termios now, rather than reporting the last sample.
    ///
    /// [`Session::mode`] answers from whatever the reader thread last saw, which is as
    /// fresh as the poll interval and no fresher. That is the right answer for a drain,
    /// which is describing a moment that has already passed. It is the wrong one for a
    /// keystroke.
    ///
    /// A child that turns echo off *without printing anything* — `read -s` with no
    /// prompt, a bare `stty -echo` — moves the tty and leaves nothing on the pty for the
    /// reader to wake on, so between that `tcsetattr` and the next sample the cached
    /// answer still says a line editor is reading when a password read is. Emacs owning
    /// the line on the strength of that is how a typed secret reaches the buffer, and it
    /// is the one staleness this crate cannot spend.
    ///
    /// So the input path asks here instead, once per typed character, and pays one
    /// `tcgetattr` for an answer that cannot be stale.
    ///
    /// The returned mode is what *this* call read, not a re-load of the cache. The
    /// distinction matters because the store races the reader thread's own: two samples
    /// taken microseconds apart can be written back in either order, so the cache can go
    /// momentarily backwards. Nothing is harmed by that — the next sample corrects it —
    /// but the caller deciding whether to insert a character must act on the tty it just
    /// read, not on whichever write happened to land last.
    pub fn sample_mode(&self) -> Mode {
        match self.shared.pty.mode() {
            Ok(mode) => {
                self.shared.mode.store(mode);
                mode
            }
            // Nothing to be learned and nothing to report: a pty that will not answer is
            // a session on its way out, and the last known mode is the honest fallback.
            Err(_) => self.shared.mode.load(),
        }
    }

    pub fn pid(&self) -> Pid {
        self.shared.pty.pid()
    }

    pub fn signal(&self, sig: Signal) -> Result<()> {
        self.shared.pty.signal(sig)
    }

    /// What is actually running on the tty right now, which is not the same question as
    /// [`Session::pid`]: the child is usually a shell, and the program the user is looking
    /// at is whatever that shell put in the foreground.
    pub fn foreground(&self) -> Result<Pid> {
        self.shared.pty.foreground()
    }

    pub fn job_control(&self) -> Result<JobControl> {
        self.shared.pty.job_control()
    }

    pub fn alive(&self) -> bool {
        self.shared.exited.held().is_none()
    }

    /// The last non-blank line — the prompt text for a [`Mode::Secret`] read.
    pub fn trailing_text(&self) -> Option<String> {
        self.shared.term.held().trailing_text()
    }

    pub fn bracketed_paste(&self) -> bool {
        self.shared.term.held().bracketed_paste()
    }

    pub fn focus_events(&self) -> bool {
        self.shared.term.held().focus_events()
    }

    pub fn alt_scroll(&self) -> bool {
        self.shared.term.held().alt_scroll()
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

impl Shared {
    /// Mark output or a mode change pending, flushing if the throttle allows.
    ///
    /// Thin over [`Notifier::announce`] because losing the wake pipe is the session's
    /// business, not the notifier's: a failed write means Emacs is gone.
    fn announce(&self) {
        if !self.notifier.announce() {
            self.shutdown.store(true, Ordering::SeqCst);
        }
    }

    /// Unconditionally send the wake byte if none is already in flight.
    ///
    /// Used directly only by `finish`: a session ending must reach Emacs right away, and
    /// the redisplay throttle is about redraw cadence, not about delaying "the child is
    /// gone." Everywhere else goes through [`Shared::announce`].
    fn notify(&self) {
        if !self.notifier.notify() {
            self.shutdown.store(true, Ordering::SeqCst);
        }
    }

    /// Copy the emulator's synchronized-output deadline where the notify path sees it.
    fn refresh_sync(&self) {
        let deadline = self.term.held().sync_deadline();
        self.notifier.set_sync(deadline);
    }

    /// How long this iteration may sleep: the notifier's answer, cut short by a pending
    /// one-shot resample if that lands sooner.
    ///
    /// Combined here rather than inside [`Notifier`] because the two deadlines are about
    /// different things — one is when Emacs next wants drawing, the other is when the tty
    /// is next worth asking about — and folding a termios concern into the notifier would
    /// put it in the one place that has no business knowing about termios at all.
    ///
    /// `min` and not `max`: an earlier deadline is a reason to wake sooner, never later.
    /// [`remaining`] answers `None` once the deadline has passed, so an expired resample
    /// contributes nothing and cannot pin the timeout at zero and spin this thread.
    fn poll_timeout(&self) -> PollTimeout {
        let mut wait = self.notifier.poll_wait();
        if let Some(left) = remaining(*self.resample_at.held()) {
            wait = wait.min(left);
        }
        PollTimeout::try_from(wait)
            .unwrap_or_else(|_| PollTimeout::from(POLL_TIMEOUT_MS))
    }

    /// Ask again shortly, because the child just wrote something; see [`RESAMPLE_DELAY`].
    fn arm_resample(&self) {
        *self.resample_at.held() = Some(std::time::Instant::now() + RESAMPLE_DELAY);
    }

    /// Retire an armed resample once its moment has come and gone.
    ///
    /// The sample itself is [`Shared::sample_mode`]'s, taken unconditionally on every tick
    /// -- this only decides *when* the tick happens, so once the deadline is behind us
    /// there is nothing left for it to bring forward.
    fn retire_resample(&self) {
        let mut at = self.resample_at.held();
        if at.is_some_and(|t| t <= std::time::Instant::now()) {
            *at = None;
        }
    }

    fn read_loop(&self) {
        block_sigpipe();
        let mut buf = vec![0u8; READ_CHUNK];

        while !self.shutdown.load(Ordering::SeqCst) {
            let mut fds = [
                PollFd::new(self.pty.as_fd(), PollFlags::POLLIN),
                PollFd::new(self.interrupt.read.as_fd(), PollFlags::POLLIN),
            ];
            match poll(&mut fds, self.poll_timeout()) {
                Err(nix::errno::Errno::EINTR) => continue,
                Err(_) => break,
                Ok(_) => {}
            }
            let interrupted = fds[1].revents().is_some_and(|r| !r.is_empty());
            let ready = fds[0].revents().is_some_and(|r| !r.is_empty());
            // Either teardown asked us to stop -- in which case do not touch the pty on the
            // way out -- or a drain left a throttled notification for the `flush` below,
            // and all that was wanted was this iteration itself.
            if interrupted {
                self.interrupt.clear();
                if self.shutdown.load(Ordering::SeqCst) {
                    return;
                }
            }

            // Sampled rather than pushed: Linux does not report ICANON/ECHO changes. The poll
            // timeout bounds the latency, and an unchanged mode costs nothing.
            if self.sample_mode() {
                self.announce();
            }
            self.retire_resample();

            // A `resize` that arrived before the child opened its slave (see `Session::resize`)
            // is retried here, on the same cadence as `sample_mode` above and for the same
            // reason: this transient clears within microseconds of `spawn` returning, so the
            // next tick of a loop that is already running is enough — no dedicated wait needed.
            self.apply_pending_resize();

            // Retries a notification `min_redisplay_interval` throttled earlier. Unconditional
            // so a quiet period still gets the last bit of output flushed within one more poll
            // cycle, rather than waiting on the next read that may never come.
            self.notifier.flush();

            if !ready {
                continue;
            }

            // Backpressure: with a full backlog, leave the bytes in the pty. Its buffer
            // fills and the child blocks in `write`, so output waits instead of being
            // dropped or piling up in memory faster than Emacs can render it.
            if self.term.held().backlog() >= self.backlog_limit {
                // A child that filled the backlog inside one frame has forfeited atomicity:
                // holding the wakeup here would deadlock the backlog against its own blocked
                // write, waiting on a frame it cannot finish because we are not reading.
                self.notifier.set_sync(None);
                self.announce();
                std::thread::sleep(std::time::Duration::from_millis(2));
                continue;
            }

            match self.pty.read(&mut buf) {
                Ok([]) => return self.finish(Ended::ChildGone),
                Ok(data) => {
                    self.term.held().feed(data);
                    // The child has just written, so the tty is worth asking about again
                    // shortly: the prompt of a secret read lands here, and the
                    // `tcsetattr` behind it a fraction of a millisecond later. See
                    // [`RESAMPLE_DELAY`].
                    self.arm_resample();
                    // A child that changes mode almost always writes at the same moment, so
                    // re-sampling here is what makes the common case feel instantaneous.
                    self.sample_mode();
                    self.refresh_sync();
                    self.announce();
                }
                // EIO is how Linux reports the last slave closing.
                Err(e) if e.is(Errno::EIO) => {
                    return self.finish(Ended::ChildGone);
                }
                Err(e) if e.is(Errno::EINTR) => {}
                Err(_) => return self.finish(Ended::Aborted),
            }
        }

        self.finish(Ended::Aborted);
    }

    fn finish(&self, why: Ended) {
        let patience = match why {
            Ended::ChildGone => REAP_PATIENCE,
            Ended::Aborted => std::time::Duration::ZERO,
        };
        let Some(status) = self.pty.reap(patience) else {
            return;
        };
        *self.exited.held() = Some(status);
        // Whether anything is left throttled is beside the point here: the byte below goes
        // out regardless, and this is the reader thread, with nothing to interrupt.
        let _ = self.notifier.drained();
        self.notify();
    }

    /// Re-read the child's termios, reporting whether it changed.
    fn sample_mode(&self) -> bool {
        self.pty.mode().is_ok_and(|mode| {
            let changed = mode != self.mode.load();
            self.mode.store(mode);
            changed
        })
    }

    /// Drive the pty to the size `Session::resize` last asked for.
    ///
    /// Cleared only once the tty *reads back* with that size, not merely once the ioctl
    /// succeeds: the child's own initialisation can overwrite a successful set, and the
    /// difference between those two is invisible without reading it back. See
    /// `Session::resize`.
    fn apply_pending_resize(&self) {
        let mut pending = self.pending_resize.held();
        let Some(size) = *pending else { return };
        if self.pty.winsize().is_ok_and(|current| current == size) {
            *pending = None;
            return;
        }
        // `ENOTTY` is the transient this loop exists for (macOS, before the child's first
        // slave open — see `Session::resize`) and is worth retrying. Anything else — the fd
        // gone bad, the ioctl refused for a reason that will not change — cannot be fixed by
        // asking again next tick, so give up on this size rather than spinning an ioctl on
        // every poll for the rest of the session over a resize that can never land.
        if let Err(e) = self.pty.resize(size)
            && !e.is(Errno::ENOTTY)
        {
            *pending = None;
        }
    }
}

enum Ended {
    /// The pty reported EOF, so the child is on its way out and can be reaped.
    ChildGone,
    /// We are tearing down; the child may well still be running.
    Aborted,
}

/// A write to the wake pipe races Emacs closing its read end. SIGPIPE is delivered to the
/// writing thread, so blocking it here turns that race into a harmless `EPIPE` instead of
/// killing Emacs.
fn block_sigpipe() {
    let mut set = SigSet::empty();
    set.add(Signal::SIGPIPE);
    let _ = set.thread_block();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emu::{self, Event};
    use nix::errno::Errno;
    use nix::fcntl::{FcntlArg, FdFlag, fcntl};
    use std::time::{Duration, Instant};

    /// `kill(pid, 0)` only probes for existence. ESRCH means the pid is gone for good.
    fn alive(pid: i32) -> nix::Result<()> {
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None)
    }

    /// Close-on-exec, because these tests fork children concurrently: a plain `pipe`
    /// leaves the read end inheritable, and `the_child_inherits_only_stdio` then sees
    /// *this* fd surviving someone else's exec and reports a leak that is the test
    /// harness' own.
    ///
    /// Deliberately not `crate::platform::cloexec_pipe`: that shim also sets
    /// `O_NONBLOCK` (needed for the real self-pipe interrupt mechanism, not for a stand-in
    /// wake channel these tests read blockingly), and plain `nix::unistd::pipe2` is a
    /// Linux-only syscall that does not exist on macOS, one of the two platforms this
    /// crate ships for — so it goes through `nix::unistd::pipe` plus `fcntl`, portable
    /// to both, close-on-exec only.
    fn pipe() -> (OwnedFd, OwnedFd) {
        let (read, write) = nix::unistd::pipe().expect("pipe");
        for fd in [read.as_fd(), write.as_fd()] {
            fcntl(fd, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC)).expect("cloexec");
        }
        (read, write)
    }

    fn session(argv: &[&str]) -> (Session, OwnedFd) {
        session_with_backlog(argv, emu::BACKLOG_HIGH_WATER)
    }

    fn session_with_backlog(argv: &[&str], backlog_limit: usize) -> (Session, OwnedFd) {
        session_with(
            argv,
            Options {
                backlog_limit,
                ..Options::default()
            },
        )
    }

    fn session_with(argv: &[&str], options: Options) -> (Session, OwnedFd) {
        let (read, write) = pipe();
        let size = Winsize {
            rows: 24,
            cols: 80,
            cell: Default::default(),
        };
        (
            Session::spawn(
                argv,
                &[("TERM", "xterm-256color")],
                size,
                None,
                write,
                options,
            )
            .expect("spawn"),
            read,
        )
    }

    /// Wait up to `patience` for a wakeup byte, reporting whether one arrived.
    ///
    /// Nonblocking, deliberately. A blocking read on this pipe cannot tell the
    /// notification a test is about from the one [`Shared::finish`] writes
    /// unconditionally when the child exits: it simply waits, the child's `sleep` ends,
    /// the byte arrives, and the assertion passes on the wrong byte. Nothing about that
    /// looks like a failure except the several seconds it took, so tests written that way
    /// stay green through the removal of the very path they name -- which is exactly what
    /// `the_wake_pipe_is_poked_on_output` and
    /// `an_unterminated_frame_is_drawn_when_the_timeout_expires` both used to do.
    fn woke_within(read: &OwnedFd, patience: Duration) -> bool {
        nix::fcntl::fcntl(
            read.as_fd(),
            nix::fcntl::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
        )
        .expect("nonblock");
        let deadline = Instant::now() + patience;
        let mut byte = [0u8; 1];
        loop {
            match nix::unistd::read(read.as_fd(), &mut byte) {
                Ok(1) => return byte[0] == 1,
                _ if Instant::now() >= deadline => return false,
                // Polled rather than blocking on the fd: the point is to give up.
                _ => std::thread::sleep(Duration::from_millis(2)),
            }
        }
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
        // The child outlives the assertion on purpose. With `printf hi` alone it exited
        // immediately, and the byte this waited for was the one `finish` sends for the
        // exit rather than the one the output was supposed to earn -- so the test passed
        // with the whole announce path deleted from the read loop.
        let (session, read) = session(&["/bin/sh", "-c", "printf hi; sleep 5"]);
        assert!(
            woke_within(&read, Duration::from_secs(2)),
            "output must poke the wake pipe while the child is still running"
        );
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
        assert!(
            !woke_within(&read, Duration::ZERO),
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
        // A short patience rather than none, for scheduling slop -- but bounded well
        // under the child's own `sleep 5`, since a blocking read here would have been
        // satisfied by the byte that the child's *exit* sends and passed regardless.
        assert!(
            woke_within(&read, Duration::from_millis(200)),
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

    /// The throttle interval these two tests run at, well above its 8ms default: what has
    /// to fit inside the window here is a round trip through the test thread rather than a
    /// gap the child controls, and it still has to sit clearly below `POLL_TIMEOUT_MS`
    /// (100ms) for the retry to be attributable to the interval rather than to the tick.
    const THROTTLED: Duration = Duration::from_millis(40);

    /// Which side of the throttled write the drain falls on.
    ///
    /// The two orderings retire a held notification by different mechanisms, so each test
    /// names the one it means. Racing for whichever turns up -- which is what a `sleep`
    /// between the child's two writes was really doing -- gives a test that passes for
    /// one reason on an idle machine and another under load, and covers neither on purpose.
    enum Drain {
        /// The reader computes its next [`Notifier::poll_wait`] already knowing the
        /// notification is Emacs' to hear, and shortens its own tick to the rest of the
        /// interval.
        BeforeTheWrite,
        /// The reader is asleep on a timeout it computed while the previous wakeup was
        /// still in flight -- a full `POLL_TIMEOUT_MS`, since a notification Emacs has not
        /// drained is not one the tick can do anything about. Only the interrupt
        /// [`Notifier::drained`] asks for can cut that short.
        AfterTheWrite,
    }

    /// How long a notification throttled by `min_redisplay_interval` takes to reach the
    /// wake pipe, with the drain placed on the `when` side of the write that was throttled.
    ///
    /// The second write is driven by input rather than by a sleep, so it cannot happen
    /// before the reader has consumed the first one: a `sleep 0.003` between two printfs
    /// is short enough that a loaded machine reads both in one go, and one read is one
    /// announcement, with no throttled second notification left to retry.
    ///
    /// Reads the wake pipe directly rather than going through `drain`, which reflects
    /// `Term`'s live state regardless of whether a wakeup was ever sent for it — exactly
    /// the property that makes throttling safe (see `min_redisplay_interval`'s docs) but
    /// also the reason `drain` cannot observe a throttled *notification* being retried
    /// late. The wake pipe is the one thing actually gated by the poll timeout.
    fn throttled_retry(when: Drain) -> Duration {
        let (session, read) = session_with(
            &[
                "/bin/sh",
                "-c",
                "printf 'first\n'; read -r _; printf 'second\n'; sleep 5",
            ],
            Options {
                min_redisplay_interval: THROTTLED,
                ..Options::default()
            },
        );
        let mut byte = [0u8; 1];
        nix::unistd::read(read.as_fd(), &mut byte).expect("first wake");

        // Draining is what clears `notified`, the same way Emacs' filter does before it
        // drains: no second wakeup can follow while the first is still in flight, so
        // without this the second wake would just be the first notification's own byte.
        // Releasing the write is what makes there be something to hold back.
        match when {
            Drain::BeforeTheWrite => {
                session.drain();
                session.send(b"\n").expect("release the second write");
            }
            Drain::AfterTheWrite => {
                session.send(b"\n").expect("release the second write");
                // Long enough that the write is certainly in, short enough that the drain
                // still lands inside the throttle window -- outside it there is nothing
                // held back, because the drain's own flush sends the byte on the spot.
                std::thread::sleep(THROTTLED / 4);
                session.drain();
            }
        }

        let start = Instant::now();
        // Bounded rather than a blocking read: a notification that never comes would
        // otherwise be answered by the byte the child's own exit sends, several seconds
        // later, and the assertion would be made against that instead.
        assert!(
            woke_within(&read, Duration::from_secs(1)),
            "the throttled notification never arrived at all"
        );
        start.elapsed()
    }

    /// A write that lands inside `min_redisplay_interval` of the previous one gets its
    /// notification throttled, and `poll_timeout` shortens the reader's tick to the rest
    /// of that interval so the retry happens at the interval's own cadence rather than
    /// waiting out the coarser `POLL_TIMEOUT_MS`.
    #[test]
    fn a_throttled_notification_is_retried_near_min_redisplay_interval_not_poll_timeout() {
        let elapsed = throttled_retry(Drain::BeforeTheWrite);
        assert!(
            elapsed < THROTTLED + THROTTLED / 2,
            "took {elapsed:?} for a throttled notification to retry; expected it near the \
             {THROTTLED:?} interval, not on a POLL_TIMEOUT_MS (100ms) tick"
        );
    }

    /// The other order, which no shortened tick can help with: the reader is already
    /// asleep for the full `POLL_TIMEOUT_MS` when Emacs drains, so clearing the flag has
    /// to interrupt the poll rather than wait for it.
    #[test]
    fn a_drain_inside_the_throttle_window_does_not_leave_the_retry_to_the_poll_timeout() {
        let elapsed = throttled_retry(Drain::AfterTheWrite);
        assert!(
            elapsed < THROTTLED + THROTTLED / 2,
            "took {elapsed:?} to retire a notification the drain found throttled; expected \
             the rest of the {THROTTLED:?} interval, not a POLL_TIMEOUT_MS (100ms) tick"
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
        let read = crate::platform::cloexec_pipe().expect("pipe");
        let wake = read.1;
        // The shim marks both ends, so clear it again on the write end — otherwise the
        // test would pass whether or not `Session::spawn` does its job.
        nix::fcntl::fcntl(
            wake.as_fd(),
            nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::empty()),
        )
        .expect("clear cloexec");
        let ours = std::fs::read_link(format!(
            "/proc/self/fd/{}",
            std::os::fd::AsRawFd::as_raw_fd(&wake)
        ))
        .expect("link");

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
            Winsize {
                rows: 24,
                cols: 80,
                cell: Default::default(),
            },
            None,
            wake,
            Options::default(),
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

    /// Teardown returns without waiting on anything of the child's.
    ///
    /// What this does *not* cover, despite what it said until recently, is the interrupt
    /// pipe. Its old comment claimed "without the quit pipe this waits out the reader's
    /// poll timeout every time", and that is not so for this child: `sh` dies on the
    /// SIGHUP that `shutdown` sends, its side of the pty closes, and the reader's `poll`
    /// returns on the pty fd whether or not anything interrupted it. The test passes with
    /// `Interrupt::raise` deleted from `shutdown` outright -- measured, not reasoned.
    ///
    /// A child that ignores SIGHUP is the case the pipe is actually for, and no test here
    /// covers it, because the win turns out to be a tail rather than a fixed cost: the
    /// reader waits out whatever is left of its current `POLL_TIMEOUT_MS` tick, which is
    /// usually little and occasionally all of it. Across twenty teardowns the totals with
    /// and without the interrupt were 8-69ms against 12-121ms -- overlapping ranges, spawn
    /// noise dominating, no threshold that separates them without flaking. What is left is
    /// this: a guard against teardown becoming grossly slow, which is worth having and is
    /// not what its comment used to say it was.
    ///
    /// The interrupt's other caller is covered, deterministically, by
    /// `a_drain_inside_the_throttle_window_does_not_leave_the_retry_to_the_poll_timeout`.
    #[test]
    fn shutdown_returns_promptly() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 300"]);
        let start = Instant::now();
        session.shutdown();
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
                .any(|e| matches!(e, Event::PromptStart(..)))
        });
        assert!(
            update
                .delta
                .events
                .iter()
                .any(|e| matches!(e, Event::PromptEnd(..)))
        );
    }

    #[test]
    fn resize_reaches_the_child() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 0.3; stty size"]);
        session
            .resize(Winsize {
                rows: 12,
                cols: 40,
                cell: Default::default(),
            })
            .expect("resize");
        let update = wait_for(&session, |u| rendered(u).contains("12 40"));
        assert!(rendered(&update).contains("12 40"));
    }
}
