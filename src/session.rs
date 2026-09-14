//! A running child: pty, emulator, and the reader thread that couples them to Emacs.
//!
//! Emacs' module functions may only be called from the thread holding an `emacs_env`, so
//! the reader never touches Lisp. It parses into the shared [`Term`] and pokes a pipe
//! descriptor obtained from `open_channel`; Emacs' filter then drains on the main thread.

use crate::emu::{Delta, Event, Term};
use crate::error::Result;
use crate::pty::{AtomicMode, JobControl, Mode, Pid, Pty, WRITE_TIMEOUT, Winsize};
use crate::replies::{ReplyKind, ReplyQueue};
use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{SigSet, Signal};
use std::ffi::OsStr;
use std::os::fd::{AsFd, OwnedFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, TryLockError};
use std::thread::JoinHandle;

/// Take a lock, treating poisoning as nothing to refuse over.
///
/// Every mutex in this file is taken this way. A poisoned mutex means a panic unwound
/// out of the emulator while it held the lock, which `env::trampoline` has already
/// reported to the user as a Lisp signal. Refusing the lock from then on would freeze
/// the buffer for good -- no drain, no resize, no teardown -- while carrying on costs at
/// worst a stale cell until the next write.
///
/// So take every lock here through `held`, never through `.lock().ok()?`: that answers
/// "no" instead of recovering, and after one poisoning would leave `drain` working while
/// `alive` reported the session dead.
///
/// Named `held` rather than `take` so that `self.reader.held().take()` reads as two
/// different operations.
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
/// No keystroke depends on it: [`Session::sample_mode`] reads the tty on the input path,
/// so a password is never typed under a stale mode whatever this says. What it does
/// bound is how soon a *silent* mode change is noticed -- a child that turns echo off and
/// prints nothing is only ever seen here.
///
/// So it is not a free knob. 250ms would take an idle session from about ten wakeups a
/// second to four, and would also stop
/// `cooked-a-child-that-exits-while-suspended-hands-the-buffer-back` and
/// `cooked-evil-normal-state-does-not-outlive-the-child`, whose children go raw silently
/// and exit 200ms later, from observing the mode at all. [`RESAMPLE_DELAY`] and
/// [`UNATTENDED_POLL_TIMEOUT`] take the parts of that saving that cost nothing.
const POLL_TIMEOUT_MS: u8 = 100;

/// The same tick, for a session nobody is looking at. See [`Session::set_attended`].
///
/// The trade [`POLL_TIMEOUT_MS`] refuses to make globally is a bargain while the buffer
/// is off screen, because a stale mode only costs somebody watching. Noticing a silent
/// mode change buys two things, raising a password prompt and swapping a keymap, and
/// neither is worth anything to a buffer in no window. No keystroke can arrive without
/// [`Session::sample_mode`] reading the tty first, and Emacs forces a sample when
/// attention returns.
///
/// Bounded rather than infinite, because the pending resize, the throttled-notification
/// retry and the resample deadline all ride on this loop turning over. Each has its own
/// wakeup, but an infinite timeout would make the tick something nothing could rely on,
/// where a second keeps every invariant working at a tenth of the rate.
const UNATTENDED_POLL_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(1000);

/// How long input keeps the eager tick on a session nobody is looking at.
///
/// `set_attended` reads "nobody is looking" off which window is selected, and that is
/// half an answer here: a wheel notch over an unselected terminal is forwarded to the
/// child without the window ever being selected. The gesture then depends on exactly
/// what the long tick lets go stale, the termios sample that `cooked--mouse-state` and
/// the keymap are read from.
///
/// So input restores the ordinary tick for this long past the last byte written to the
/// child. It never goes faster than [`POLL_TIMEOUT_MS`]: how fast a session draws is
/// `min_redisplay_interval` and Emacs' own readiness, neither of which this touches.
///
/// Half a second because it has to span the gaps *within* a gesture: wheel notches arrive
/// tens of milliseconds apart and a hand pauses between flicks, so anything shorter drops
/// back to the long tick mid-scroll.
const INTERACTION_WINDOW: std::time::Duration = std::time::Duration::from_millis(500);

/// How long after a burst of output to take one extra termios sample.
///
/// The common secret read does not arrive silently: `read -s -p`, `getpass` and `sudo`
/// all write their prompt and change the tty within a fraction of a millisecond of each
/// other, in that order -- about 0.03ms apart on the shells measured, which is also why
/// `cooked-secret-debounce` on the Lisp side is 0.03s.
///
/// So the sample taken immediately after a read is a coin flip, and the next one is
/// [`POLL_TIMEOUT_MS`] away. One extra sample in the wake of output catches the prompt
/// promptly without shortening the base tick, and a session with no output arms nothing.
const RESAMPLE_DELAY: std::time::Duration = std::time::Duration::from_millis(50);
/// How long to wait for a child that closed the pty to become reapable.
const REAP_PATIENCE: std::time::Duration = std::time::Duration::from_millis(500);
/// How long an explicit shutdown gives the child to honour SIGHUP before SIGKILL,
/// and again to become reapable afterwards.
const KILL_GRACE: std::time::Duration = std::time::Duration::from_millis(50);

/// How quiet the pty must go before a frame is drawn; see [`NotifyState::hold`].
///
/// A client update is written in pieces — `viu` sends a cursor move, then four megabytes
/// of image, then a newline — and drawing between two of them shows a state the client
/// never meant anyone to see. foot names this exact bug in `term.c` and mitigates it the
/// same way, with the same 0.5ms: "this causes screen 'flickering'."
///
/// Half a millisecond because it has to sit above the gaps *within* an update and below
/// anything a person can perceive. Measured on this machine, reading a gif at 166MB over
/// six seconds: the gap between consecutive reads is 32us at the median and 102us at the
/// 99th percentile, while the gap *between* frames is 16ms and up. There is a factor of
/// a hundred of daylight between the two, and this sits in the middle of it.
const QUIESCENCE: std::time::Duration = std::time::Duration::from_micros(500);

/// The longest a frame may be held for a client that will not stop writing.
///
/// [`QUIESCENCE`] waits for the pty to go quiet and [`NotifyState::frame_ceiling`] bounds
/// that wait for a client that keeps *changing* the screen. Neither covers a client that
/// keeps writing without changing anything: every read pushes `last_read` forward, and
/// the ceiling waits for a second drawable change that never comes. A child that prints
/// one line and then writes `ESC [ 0 m` flat out would never be drawn at all.
///
/// So this is a backstop: long enough that an ordinary transfer finishes inside it, short
/// enough that nobody watching calls it a freeze. It is
/// [`SYNC_TIMEOUT`](crate::emu::term::SYNC_TIMEOUT) exactly, because a client using DEC
/// mode 2026 is made the same promise, and one number for how long anything may hold the
/// buffer still cannot drift from a second.
const HOLD_CEILING: std::time::Duration = crate::emu::term::SYNC_TIMEOUT;

/// A snapshot handed to Lisp on each drain.
pub(crate) struct Update {
    pub delta: Delta,
    pub mode: Mode,
    pub exit: Option<i32>,
}

/// Telling Emacs there is something to look at, and how often it is willing to hear it.
///
/// These pieces are only ever touched together, and gathering them gives the wake
/// descriptor an owner, so it need not be threaded as a parameter through everything
/// that might flush. The timing state shares one mutex because `flush` and `poll_wait`
/// read all of it at once.
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
    /// See [`QUIESCENCE`].
    quiescence: std::time::Duration,
}

struct NotifyState {
    /// Floor on how often the wake pipe is written to, however fast output arrives.
    /// Without one, a spinner rewriting its line drives one full Emacs redisplay per write
    /// and shows up as flicker. It says how close together two wakeups may be and nothing
    /// about which moment is worth drawing, which is [`Self::hold`]'s question.
    ///
    /// `Term` always holds the latest state, and [`Notifier::poll_wait`] shortens the
    /// reader's tick to this interval's remaining window so a throttled notification is
    /// not left waiting out `POLL_TIMEOUT_MS`.
    ///
    /// Here rather than on [`Notifier`] because Emacs may change
    /// `cooked-min-redisplay-interval' on a running session, and under this lock the
    /// interval and the `last` it is compared against change together.
    min_interval: std::time::Duration,
    /// How long a frame may be held while the child keeps changing it; see
    /// [`Self::hold`].
    ///
    /// Derived from `min_interval` by [`Options::with_min_redisplay_interval`] rather than
    /// chosen beside it. [`Notifier::flush`] consults the throttle before the hold, so a
    /// continuously-writing child is redrawn at the longer of the two, and an independent
    /// number could only be dead weight or overrule a user who asked for a faster
    /// interval. The rule is therefore that a held frame is never held longer than one
    /// redisplay interval; the 8ms default makes that half a 60Hz frame, which is foot's
    /// `delayed-render-time-upper`.
    ///
    /// Without a ceiling, a full-screen program repainting flat out never gives
    /// [`QUIESCENCE`] the gap it waits for, and an alternate-screen repaint archives nothing
    /// for `backlog_limit` to catch.
    ///
    /// Armed at the *second* change of a held frame rather than the first. One cursor move
    /// followed by a long silent image transfer has nothing further to show, and firing on
    /// it would draw the cursor on top of a picture that has not arrived. A client that is
    /// genuinely streaming changes produces its second one within microseconds, so it arms
    /// this at once and is redrawn at the redisplay interval throughout.
    frame_ceiling: std::time::Duration,
    /// When the wake pipe was last actually written to, for `min_interval`.
    last: Option<std::time::Instant>,
    /// While set and unexpired, the child is mid-frame under DEC mode 2026 and has asked
    /// not to be drawn yet. Refreshed from `Term` under the lock the reader already holds,
    /// so no path takes an extra one — and never *extended* while the frame it is holding
    /// is still undrawn; see [`Notifier::set_sync`].
    sync_until: Option<std::time::Instant>,
    /// When the child last wrote anything at all, drawable or not; see [`Self::hold`].
    ///
    /// Every read moves it, including the ones that changed nothing: a megabyte of image
    /// data changes no cell, and is still the loudest possible evidence that the client
    /// is in the middle of an update.
    last_read: Option<std::time::Instant>,
    /// When a frame that has changed more than once stops being held; see
    /// [`Self::frame_ceiling`]. `None` while no frame is held, and while the held frame has
    /// only the one change in it.
    ceiling_at: Option<std::time::Instant>,
    /// When the frame currently being held first became one, for [`HOLD_CEILING`]. `None`
    /// while nothing is held. Distinct from `ceiling_at`, which is armed by a *second*
    /// change and is the pace a busy client is drawn at; this is armed by the first and is
    /// the outer bound on the whole hold, however quiet or noisy the client turns out to be.
    held_since: Option<std::time::Instant>,
}

impl NotifyState {
    /// How much longer this frame is being held back for the child to finish writing it,
    /// or `None` if it is due to be drawn now.
    ///
    /// The quiescence rule. It has the same shape as DEC mode 2026 -- hold the frame, keep
    /// `dirty` set, retire at a deadline -- with the pty going quiet standing in for the
    /// child's cooperation, so it works for clients that never send a 2026 sequence.
    ///
    /// Two deadlines, whichever comes first: [`QUIESCENCE`] since the last byte arrived,
    /// and [`Self::frame_ceiling`] since the frame's second change. `last_read` unset — which
    /// [`Notifier::announce`] arranges — means there is nothing to wait for at all.
    fn hold(&self, quiescence: std::time::Duration) -> Option<std::time::Duration> {
        let mut wait = remaining(self.last_read.map(|t| t + quiescence))?;
        // `None` from either deadline below means it has *passed*, which releases the
        // frame, so each is asked separately rather than folded into the `min` with a
        // default that would read as "no deadline".
        if let Some(at) = self.ceiling_at {
            wait = wait.min(remaining(Some(at))?);
        }
        if let Some(since) = self.held_since {
            wait = wait.min(remaining(Some(since + HOLD_CEILING))?);
        }
        Some(wait)
    }
}

impl Notifier {
    fn new(wake: OwnedFd, options: &Options) -> Self {
        Self {
            wake: Mutex::new(Some(wake)),
            dirty: AtomicBool::new(false),
            notified: AtomicBool::new(false),
            state: Mutex::new(NotifyState {
                min_interval: options.min_redisplay_interval,
                frame_ceiling: options.frame_ceiling,
                last: None,
                held_since: None,
                sync_until: None,
                last_read: None,
                ceiling_at: None,
            }),
            quiescence: options.quiescence,
        }
    }

    /// Adopt a new redisplay interval, and the ceiling that derives from it.
    ///
    /// The far end of `cooked-min-redisplay-interval''s `:set'. Taken under the lock its
    /// readers already hold, so a change cannot land between [`Self::flush`] reading the
    /// interval and reading the `last` it compares against.
    ///
    /// Nothing is rescheduled: a frame already being held keeps the deadline it was given,
    /// and later frames use the new one. Recomputing `ceiling_at` here would let a user
    /// dragging a customize slider keep re-arming the hold on a frame ready to draw.
    fn set_pacing(&self, min_interval: std::time::Duration, frame_ceiling: std::time::Duration) {
        let mut state = self.state.held();
        state.min_interval = min_interval;
        state.frame_ceiling = frame_ceiling;
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

    /// Mark something pending that is not part of a frame, and flush it if the throttle
    /// allows.
    ///
    /// Clearing the quiescence deadlines is what "not part of a frame" means. A termios
    /// change, a full backlog or an exited child is nothing the child will finish writing,
    /// and `getpass` turning echo off just after printing its prompt must not wait on the
    /// rest of an update.
    fn announce(&self) -> bool {
        self.dirty.store(true, Ordering::SeqCst);
        let mut state = self.state.held();
        state.last_read = None;
        state.ceiling_at = None;
        state.held_since = None;
        drop(state);
        self.flush()
    }

    /// Note a read from the pty, `drawable` saying whether it changed anything Emacs
    /// would draw.
    ///
    /// The entry point for output, in place of [`Self::announce`]: it marks the frame and
    /// leaves the decision of when to draw it to [`Self::flush`], which the reader
    /// retries on every tick. Both halves of [`NotifyState::hold`] are armed here — the
    /// timestamp on every read, and the ceiling from the second drawable change onwards,
    /// which is what `dirty` already being set says.
    fn fed(&self, drawable: bool) {
        let now = std::time::Instant::now();
        let mut state = self.state.held();
        state.last_read = Some(now);
        if drawable {
            if self.dirty.swap(true, Ordering::SeqCst) {
                let ceiling = state.frame_ceiling;
                state.ceiling_at.get_or_insert(now + ceiling);
            } else {
                // The first change of a frame, which [`HOLD_CEILING`] is measured from. One
                // change is not yet evidence that more are coming, so `ceiling_at` waits.
                state.held_since = Some(now);
            }
        }
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
        if state.last.is_some_and(|t| t.elapsed() < state.min_interval) {
            return true;
        }
        // Same reasoning as the sync check above, and the same handling: the frame stays
        // dirty and the retry machinery draws it the moment the child stops writing.
        if state.hold(self.quiescence).is_some() {
            return true;
        }
        state.last = Some(std::time::Instant::now());
        state.ceiling_at = None;
        state.held_since = None;
        drop(state);
        self.dirty.store(false, Ordering::SeqCst);
        self.notify()
    }

    /// Emacs has taken the delta, so the wake byte we sent has done its work.
    ///
    /// This says nothing about when the next byte may go out; [`Self::rearm`] does, and
    /// Lisp calls it once the buffer is drawn. The two sit at opposite ends of Emacs' work
    /// because taking a delta is cheap and drawing it is the whole cost of a frame -- about
    /// 12ms for a screen of box drawing. Re-arming here would end the backpressure window
    /// before the render, and `min_interval` would always have elapsed by the time it was
    /// consulted.
    fn acknowledge(&self) {
        self.notified.store(false, Ordering::SeqCst);
    }

    /// Emacs has finished drawing, so the next change is worth another byte.
    ///
    /// Returns whether a throttled notification is still waiting. Flushing here retires
    /// the ordinary case, where the render lands after `min_interval` has already elapsed.
    /// A re-arm that lands inside the window leaves the retry to the reader thread — which
    /// computed its [`Shared::poll_timeout`] while the previous wakeup was still in flight,
    /// and so is asleep for the whole of `POLL_TIMEOUT_MS` rather than for the few
    /// milliseconds this notification actually has left to wait. That is the caller's cue
    /// to interrupt the poll so the timeout is computed again.
    fn rearm(&self) -> bool {
        self.flush();
        self.dirty.load(Ordering::SeqCst) && !self.notified.load(Ordering::SeqCst)
    }

    /// Copy the emulator's synchronized-output deadline where the notify path can see it.
    ///
    /// Adopted only when no frame is already being held, which is what stops a client
    /// holding the buffer still indefinitely. The emulator arms
    /// [`crate::emu::term::SYNC_TIMEOUT`] at every BSU, so taking the newest deadline each
    /// time would let a client that begins its next frame before the last was drawn -- a
    /// full-screen program under a stream of wheel notches -- push the deadline out on
    /// every read and never be drawn.
    ///
    /// So the first deadline of a held frame counts, and a later BSU leaves it alone.
    /// `None` still clears it at once, because that is ESU, the client saying the frame is
    /// finished. Once a flush clears `dirty`, the next BSU starts a fresh frame and is
    /// adopted as usual. Like [`NotifyState::frame_ceiling`], the hold is bounded from when
    /// it began rather than from the last thing the child said.
    fn set_sync(&self, deadline: Option<std::time::Instant>) {
        let mut state = self.state.held();
        match deadline {
            None => state.sync_until = None,
            Some(deadline) => {
                let held = self.dirty.load(Ordering::SeqCst) && state.sync_until.is_some();
                if !held {
                    state.sync_until = Some(deadline);
                }
            }
        }
    }

    /// How long the reader thread may sleep in `poll`.
    ///
    /// `base` is the caller's answer for the quiet case, [`POLL_TIMEOUT_MS`] or
    /// [`UNATTENDED_POLL_TIMEOUT`]. It is a parameter because how often the tty is worth
    /// asking about is a termios question, which the notifier has no business knowing.
    /// What the notifier owns are the deadlines below, which override the base.
    ///
    /// Real pty data wakes `poll` at once, so the base is coarse. But when [`Self::flush`]
    /// has deferred a notification to the throttle and the child then falls quiet, nothing
    /// else wakes the loop, and waiting out `POLL_TIMEOUT_MS` would add up to 100ms to the
    /// last frame of a burst -- felt as a stutter at the end of a wheel scroll in a
    /// full-screen program. Shortening the poll to the remaining window avoids that.
    fn poll_wait(&self, base: std::time::Duration) -> std::time::Duration {
        if self.notified.load(Ordering::SeqCst) || !self.dirty.load(Ordering::SeqCst) {
            return base;
        }
        let state = self.state.held();
        let throttle = state
            .last
            .map(|t| state.min_interval.saturating_sub(t.elapsed()))
            .unwrap_or_default();
        // A frame held by DEC mode 2026 or by the quiescence hold keeps `dirty` set with
        // nothing to flush, so the throttle's remainder is typically zero, and polling on
        // that would spin this thread for the length of the frame. Taking the latest
        // deadline avoids that and retires each hold on time.
        let wait = throttle
            .max(remaining(state.sync_until).unwrap_or_default())
            .max(state.hold(self.quiescence).unwrap_or_default());
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
    /// Replies the child is owed and has not yet taken; see [`crate::replies`].
    ///
    /// Held only for as long as it takes to queue or to offer the pty a non-blocking
    /// write, so any thread may take it, the reader included, without waiting on the
    /// child.
    replies: Mutex<ReplyQueue>,
    /// Held by whoever is writing to the pty, so that input and replies never interleave.
    ///
    /// A reply cut in two by a keystroke is two garbled sequences. [`Session::send`] holds
    /// this for as long as its write takes, which can be `WRITE_TIMEOUT`; everything else
    /// only ever `try_lock`s it, and leaves the queue to the sender when it is busy. See
    /// [`Shared::flush_replies`].
    writer: Mutex<()>,
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
    /// Pending items -- scrolled-off lines plus undelivered events -- at which the reader
    /// stops pulling from the pty and lets the child block. Raising it does not make
    /// rendering faster, since Emacs bounds throughput; it lets a child run ahead and exit
    /// sooner, at the cost of memory and a larger redisplay when the drain lands. It is
    /// tuned with `min_redisplay_interval`, since a longer interval leaves more to
    /// accumulate between drains.
    ///
    /// Atomic because Emacs may set `cooked-backlog-limit' on a running session. Relaxed
    /// ordering is enough: the worst a stale read can do is let one more chunk through.
    backlog_limit: AtomicUsize,
    shutdown: AtomicBool,
    /// Whether anyone is looking at this session's buffer; see [`Session::set_attended`].
    /// Starts true, so a session Emacs never reports on — a test, a buffer driven from
    /// Lisp — keeps the eager tick it has always had.
    attended: AtomicBool,
    /// Whether no window shows this session's buffer; see [`Session::set_hidden`]. Starts
    /// false, for the reason `attended` starts true.
    hidden: AtomicBool,
    /// When the eager tick, restored by input, stops being owed to an unattended session;
    /// see [`INTERACTION_WINDOW`]. `None` until something is sent to the child.
    ///
    /// A deadline rather than a flag so nothing has to remember to clear it: a gesture
    /// that ends because the user let go decays on its own.
    interacted_until: Mutex<Option<std::time::Instant>>,
    interrupt: Interrupt,
    exited: Mutex<Option<i32>>,
}

/// A self-pipe the reader polls alongside the pty, so the two things that can happen
/// while the child is quiet do not have to wait out the poll timeout.
///
/// Teardown is one: without this, every kill blocks Emacs for up to [`POLL_TIMEOUT_MS`].
/// A re-arm that leaves a throttled notification behind is the other; see
/// [`Notifier::rearm`]. Neither carries a payload — [`Shared::shutdown`] tells the two
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

/// The tuning knobs [`Session::spawn`] takes, named rather than positional, with their
/// defaults in the [`Default`] impl beside the fields they belong to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Options {
    /// See [`NotifyState::min_interval`].
    pub min_redisplay_interval: std::time::Duration,
    /// See [`QUIESCENCE`].
    pub quiescence: std::time::Duration,
    /// See [`NotifyState::frame_ceiling`].
    pub frame_ceiling: std::time::Duration,
    /// See [`Shared::backlog_limit`].
    pub backlog_limit: usize,
    /// The pictures Emacs can show, set on the emulator before the child runs.
    ///
    /// Nothing by default. A child can probe in its first instant, before Lisp has had a
    /// chance to say anything after the spawn returns, and that probe used to be answered
    /// from the emulator's own default, which claims everything. Hidden-until-told is the
    /// answer that is never a blank rectangle: a producer wrongly refused draws in half
    /// blocks.
    pub graphics: crate::emu::ShownFormats,
}

impl Options {
    /// The defaults, with `min_redisplay_interval` set to what the caller asked for and
    /// everything that derives from it following.
    ///
    /// The one way to choose the interval. [`NotifyState::frame_ceiling`] derives from it,
    /// so `Options { min_redisplay_interval: x, ..Default::default() }` would silently keep
    /// the ceiling of the *default* interval; a constructor sets both in one expression.
    pub(crate) fn with_min_redisplay_interval(min_redisplay_interval: std::time::Duration) -> Self {
        Self {
            min_redisplay_interval,
            // A field rather than [`QUIESCENCE`] read directly so tests can widen it: half
            // a millisecond is not a gap a shell can produce on demand. Tests pin
            // `frame_ceiling` the same way. Lisp offers neither;
            // `cooked-min-redisplay-interval` is the one redisplay knob users get.
            quiescence: QUIESCENCE,
            frame_ceiling: min_redisplay_interval,
            backlog_limit: crate::emu::BACKLOG_HIGH_WATER,
            graphics: crate::emu::ShownFormats::NONE,
        }
    }
}

impl Default for Options {
    fn default() -> Self {
        Self::with_min_redisplay_interval(std::time::Duration::from_millis(8))
    }
}

/// A live child, its emulator, and the reader thread coupling them to Emacs.
///
/// The owned resources sit behind mutexes rather than in plain `Option`s because
/// [`Session::shutdown`] runs through the `&Session` that Emacs' user-pointer hands
/// back, so there is never a `&mut` to be had.
pub(crate) struct Session {
    shared: Arc<Shared>,
    reader: Mutex<Option<JoinHandle<()>>>,
}

impl Session {
    /// Spawn `argv` and start reading. `wake` is a writable descriptor from
    /// `open_channel`, taken over by the session.
    pub(crate) fn spawn(
        argv: &[impl AsRef<OsStr>],
        env: &[(impl AsRef<str>, impl AsRef<str>)],
        size: Winsize,
        cwd: Option<&Path>,
        wake: OwnedFd,
        options: Options,
    ) -> Result<Self> {
        // Mark the wake descriptor close-on-exec *before* forking. `open_channel` hands it
        // over without FD_CLOEXEC, so a child would otherwise inherit the write end of the
        // pipe Emacs watches, free to poke our redisplay and keeping it from reaching EOF.
        nix::fcntl::fcntl(
            wake.as_fd(),
            nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
        )?;

        let pty = Pty::spawn(argv, env, size, cwd)?;
        let mode = pty.mode().unwrap_or_default();
        let mut term = Term::new(size.rows.into(), size.cols.into());
        // XTGETTCAP answers for the entry the child was told about, and this is where
        // what it was told is known: Lisp chose TERM, and it arrives here with the rest.
        if let Some((_, name)) = env.iter().find(|(k, _)| k.as_ref() == "TERM") {
            term.set_terminfo(name.as_ref());
        }
        // The reader sends what it can answer itself, so a reply never waits on a drain.
        term.answer_directly();
        term.set_graphics_shown(options.graphics);
        let shared = Arc::new(Shared {
            pty,
            term: Mutex::new(term),
            replies: Mutex::new(ReplyQueue::default()),
            writer: Mutex::new(()),
            mode: AtomicMode::new(mode),
            pending_resize: Mutex::new(None),
            notifier: Notifier::new(wake, &options),
            resample_at: Mutex::new(None),
            backlog_limit: AtomicUsize::new(options.backlog_limit),
            shutdown: AtomicBool::new(false),
            attended: AtomicBool::new(true),
            hidden: AtomicBool::new(false),
            interacted_until: Mutex::new(None),
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
    /// short grace period, then SIGKILL, because a child that ignores SIGHUP -- `nohup`,
    /// `trap '' HUP` -- would otherwise survive an explicit kill and never be reaped.
    pub(crate) fn shutdown(&self) -> bool {
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

    /// The emulator, locked, for a caller that only needs to ask it something or tell it
    /// something.
    ///
    /// The methods on `Session` itself are the ones with policy of their own -- a resize
    /// that also sets the tty, a send that counts as interaction -- so a plain question
    /// about the grid goes straight to [`Term`] rather than through a one-line forwarder
    /// here.
    pub(crate) fn term(&self) -> MutexGuard<'_, Term> {
        self.shared.term.held()
    }

    /// [`Session::drain_with`] for a consumer that promotes nothing, which is what the
    /// tests here read.
    #[cfg(test)]
    pub(crate) fn drain(&self) -> Update {
        self.drain_with(false)
    }

    /// Collect everything that changed, acknowledging the wakeup that asked for it.
    ///
    /// PROMOTE says the consumer keeps a screen of its own, as a cooked buffer does, and
    /// can promote the scrolled rows it already holds; see [`Delta::promoted`]. The
    /// compile pump reads the scrollback as text and does not.
    ///
    /// Acknowledging is not re-arming: the next wake byte waits on [`Session::ready`],
    /// which Emacs calls once it has drawn what this returned. See
    /// [`Notifier::acknowledge`] for why the window covers the render rather than the
    /// collection.
    ///
    /// [`Delta::promoted`]: crate::emu::Delta::promoted
    pub(crate) fn drain_with(&self, promote: bool) -> Update {
        self.shared.notifier.acknowledge();
        let mut term = self.shared.term.held();
        let delta = if promote {
            term.drain_promoting()
        } else {
            term.drain()
        };
        drop(term);
        Update {
            delta,
            mode: self.shared.mode.load(),
            exit: *self.shared.exited.held(),
        }
    }

    /// [`Session::drain_with`] for a buffer no window shows; see [`Term::drain_hidden`].
    ///
    /// Whole once the child has exited. The screen it left is what the buffer keeps, and
    /// Lisp appends its exit line below that screen, which has to be there first.
    pub(crate) fn drain_hidden(&self) -> Update {
        self.shared.notifier.acknowledge();
        let exit = *self.shared.exited.held();
        let mut term = self.shared.term.held();
        let delta = if exit.is_some() {
            term.drain()
        } else {
            term.drain_hidden()
        };
        Update {
            delta,
            mode: self.shared.mode.load(),
            exit,
        }
    }

    /// Emacs has drawn the last drain and will take another wakeup.
    ///
    /// One wake byte is in flight until this is called, so the child's writes accumulate
    /// in [`Term`] rather than each buying a redisplay. Calling it here, after the render,
    /// makes `min_redisplay_interval` a floor on the rendering rate, which is where the
    /// cost is.
    ///
    /// Safe to omit, as the tests and the benchmark do: a session nobody re-arms is woken
    /// by the reader's ordinary tick instead, slower but never stuck.
    /// `cooked--drain-and-apply` still calls it from an `unwind-protect` cleanup.
    pub(crate) fn ready(&self) {
        // The drain's events are handled, so Lisp has queued every answer it owed, and the
        // replies that waited behind them may follow.
        let outbound = {
            let mut term = self.shared.term.held();
            term.events_handled();
            term.take_outbound()
        };
        self.shared.queue_replies(outbound);
        self.flush_replies();
        if self.shared.notifier.rearm() {
            self.shared.interrupt.raise();
        }
    }

    /// Write BYTES to the child, and count that as the user interacting with this
    /// session; see [`Shared::interacted`].
    ///
    /// Waits up to `WRITE_TIMEOUT` for the child to take them, and fails after that, as a
    /// paste into a stopped job always has. Replies already queued go first, inside the
    /// same deadline: they were owed before this input was typed, and writing input
    /// between the halves of a reply would garble both.
    pub(crate) fn send(&self, bytes: &[u8]) -> Result<()> {
        self.shared.interacted();
        let deadline = std::time::Instant::now() + WRITE_TIMEOUT;
        let writer = self.shared.writer.held();
        let result = self.shared.write_after_replies(bytes, deadline);
        // A reply queued while the writer was held found it busy and left itself here, so
        // offer the queue once more. The writer is released with the queue still locked:
        // a reply queued after that finds the writer free and goes out on its own.
        let mut queue = self.shared.replies.held();
        let _ = queue.flush(|b| self.shared.pty.write_some(b));
        drop(writer);
        let waiting = !queue.is_empty();
        drop(queue);
        if waiting {
            self.shared.interrupt.raise();
        }
        result
    }

    /// Owe the child BYTES, a reply Lisp composed, without waiting for it to read them.
    ///
    /// Queued and written as far as the pty takes them now; the reader thread writes the
    /// rest once there is room. A child that has stopped reading for long enough loses
    /// the reply rather than growing the queue; see [`ReplyQueue::push`]. Not counted as
    /// interaction, since the user did nothing.
    pub(crate) fn reply(&self, bytes: &[u8]) {
        self.shared.replies.held().push(ReplyKind::Answer, bytes);
        self.flush_replies();
    }

    /// Write queued replies from Emacs' thread, and wake the reader to finish the job
    /// if the pty had no room for all of them.
    ///
    /// The reader was asleep on a poll computed while the queue was empty, and it only
    /// watches for room while something is waiting.
    fn flush_replies(&self) {
        if self.shared.flush_replies() {
            self.shared.interrupt.raise();
        }
    }

    /// Resize the emulator and the pty, and keep asking until the child agrees.
    ///
    /// One attempt from here, because this runs on the thread holding the `emacs_env` and
    /// must never wait out a retry. One attempt is not enough to be sure it took, for two
    /// reasons that both bite just after `spawn`:
    ///
    /// On macOS the ptmx master answers no winsize ioctl -- `ENOTTY` -- until the child
    /// has opened the slave.
    ///
    /// And everywhere, `child_exec` sets the initial winsize on its own slave fd after the
    /// fork, overwriting a resize that landed in between. Emacs hits this on every start:
    /// it spawns at 24x80 before the buffer has a window, and `cooked--display` resizes
    /// milliseconds later.
    ///
    /// So the size is recorded as pending, and the reader thread re-applies it until the
    /// tty reads back with it. That converges within a poll tick and then stops, so a
    /// child that later sets its own size is left alone.
    pub(crate) fn resize(&self, size: Winsize) -> Result<()> {
        // The cell size is reported together with the rows and columns because they
        // change together: a font change moves both in one event.
        let report =
            self.shared
                .term
                .held()
                .set_size(size.rows.into(), size.cols.into(), size.cell);
        *self.shared.pending_resize.held() = Some(size);
        // Wake the reader rather than leaving the retry to its next tick, which under
        // [`UNATTENDED_POLL_TIMEOUT`] can be a second away for a buffer resized while off
        // screen. Resizes are rare, so the extra wakeup costs nothing.
        self.shared.interrupt.raise();
        let result = match self.shared.pty.resize(size) {
            // Not ours to set yet; the reader thread keeps trying.
            Err(e) if e.is(Errno::ENOTTY) => Ok(()),
            result => result,
        };
        // Mode 2048's report, after the ioctl so that a child that asks the tty reads the
        // same size. Queued here rather than returned to Lisp, since sending it involves no
        // decision, and queued rather than written, because windows are resized in bursts
        // while an edge is dragged and a child that has stopped reading must not stall
        // each one. A report still waiting is replaced, so the burst queues one.
        if let Some(report) = report {
            self.shared
                .replies
                .held()
                .push(ReplyKind::SizeReport, &report);
            self.flush_replies();
        }
        result
    }

    /// The reader thread's last sample. Lisp reads this off the drain's `:mode' instead,
    /// so only the tests ask the session directly.
    #[cfg(test)]
    pub(crate) fn mode(&self) -> Mode {
        self.shared.mode.load()
    }

    /// Re-read the child's termios now, rather than reporting the last sample.
    ///
    /// The drain's `:mode' is as fresh as the reader's last sample, which is right for a
    /// drain and wrong for a keystroke. A child that turns echo off without printing --
    /// `read -s` with no prompt -- leaves nothing on the pty to wake the reader, so the
    /// cached answer can still say a line editor is reading during a password read, and
    /// Emacs owning the line on that basis is how a secret reaches the buffer. So the
    /// input path asks here, paying one `tcgetattr` per typed character.
    ///
    /// The returned mode is what *this* call read, not a re-load of the cache: the store
    /// races the reader thread's, so the cache can go briefly backwards, and the caller
    /// deciding whether to insert a character must act on the tty it just read.
    pub(crate) fn sample_mode(&self) -> Mode {
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

    /// Say whether anyone is looking at this session, which sets the tick it polls on.
    ///
    /// Attended is [`POLL_TIMEOUT_MS`]; unattended is [`UNATTENDED_POLL_TIMEOUT`], ten
    /// times longer, because the tick only notices silent termios changes and there is
    /// nobody to tell. Emacs decides what "looking" means, from `cooked--attention`.
    ///
    /// [`Shared::interacted`] also restores the eager tick whenever anything is sent to
    /// the child, so unattended is a resting state the user is never stuck in while
    /// scrolling an unselected window. The two are combined in [`Shared::base_poll_wait`].
    ///
    /// Regaining attention raises the interrupt, so the reader does not sleep out a long
    /// poll already in progress. The mode itself is made fresh by Emacs forcing a
    /// [`Session::sample_mode`] as it re-enters.
    pub(crate) fn set_attended(&self, attended: bool) {
        if self.shared.attended.swap(attended, Ordering::Relaxed) != attended && attended {
            self.shared.interrupt.raise();
        }
    }

    /// Say whether any window shows this session's buffer, which decides what output wakes
    /// Emacs; see [`Term::feed_hidden`].
    ///
    /// Coming back announces, because output that woke nothing while hidden is still
    /// waiting to be drawn, and a child that has since gone quiet would not wake Emacs
    /// again. Lisp drains the buffer whole as its window is drawn as well, and whichever
    /// comes second finds nothing.
    pub(crate) fn set_hidden(&self, hidden: bool) {
        if self.shared.hidden.swap(hidden, Ordering::Relaxed) && !hidden {
            self.shared.announce();
        }
    }

    /// Adopt a new redisplay interval and backlog limit on a session already running.
    ///
    /// Not `set_pacing`, because only the interval is a pace. The backlog limit is
    /// backpressure: how much may pile up while Emacs falls behind before
    /// [`Shared::read_loop`] stops reading and the child blocks in `write`. The two travel
    /// together because they are tuned together -- a longer interval fills the queue
    /// sooner.
    ///
    /// `frame_ceiling` is derived through the same [`Options`] constructor spawn uses, so a
    /// held frame is never held longer than one redisplay interval after a `setq` either.
    ///
    /// Nothing is woken: the reader picks the values up on its next turn, at most one poll
    /// tick away.
    pub(crate) fn set_tuning(
        &self,
        min_redisplay_interval: std::time::Duration,
        backlog_limit: usize,
    ) {
        let options = Options::with_min_redisplay_interval(min_redisplay_interval);
        self.shared
            .notifier
            .set_pacing(options.min_redisplay_interval, options.frame_ceiling);
        self.shared
            .backlog_limit
            .store(backlog_limit, Ordering::Relaxed);
    }

    pub(crate) fn pid(&self) -> Pid {
        self.shared.pty.pid()
    }

    pub(crate) fn signal(&self, sig: Signal) -> Result<()> {
        self.shared.pty.signal(sig)
    }

    /// What is actually running on the tty right now, which is not the same question as
    /// [`Session::pid`]: the child is usually a shell, and the program the user is looking
    /// at is whatever that shell put in the foreground.
    pub(crate) fn foreground(&self) -> Result<Pid> {
        self.shared.pty.foreground()
    }

    pub(crate) fn job_control(&self) -> Result<JobControl> {
        self.shared.pty.job_control()
    }

    pub(crate) fn alive(&self) -> bool {
        self.shared.exited.held().is_none()
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

    /// Retire a notification the throttle or the quiescence rule held back earlier.
    fn flush(&self) {
        if !self.notifier.flush() {
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
    /// Combined here rather than in [`Notifier`] because one deadline is about drawing and
    /// the other about termios, which the notifier has no business knowing.
    ///
    /// `min`, because an earlier deadline is a reason to wake sooner. [`remaining`] answers
    /// `None` once a deadline has passed, so an expired resample cannot pin the timeout at
    /// zero and spin this thread. The unattended stretch is only the base, so pending
    /// deadlines still cut it short.
    fn poll_timeout(&self) -> PollTimeout {
        let mut wait = self.notifier.poll_wait(self.base_poll_wait());
        if let Some(left) = remaining(*self.resample_at.held()) {
            wait = wait.min(left);
        }
        PollTimeout::try_from(wait).unwrap_or_else(|_| PollTimeout::from(POLL_TIMEOUT_MS))
    }

    /// How long a quiet tick lasts, which is the whole of what attention changes.
    ///
    /// Two things earn the eager tick: attention, which is Emacs saying the buffer is under
    /// the user's eyes, and [`INTERACTION_WINDOW`], which covers a terminal being scrolled
    /// in an unselected window.
    fn base_poll_wait(&self) -> std::time::Duration {
        if self.attended.load(Ordering::Relaxed) || self.interacting() {
            std::time::Duration::from_millis(u64::from(POLL_TIMEOUT_MS))
        } else {
            UNATTENDED_POLL_TIMEOUT
        }
    }

    /// Whether input has been sent recently enough to owe this session the eager tick.
    fn interacting(&self) -> bool {
        remaining(*self.interacted_until.held()).is_some()
    }

    /// Note that the user just did something to this session, whoever is looking at it.
    ///
    /// Called from the one place every byte bound for the child passes through, so no
    /// input path can forget it. Automatic writes such as a focus report go through it too;
    /// they are rare, and a child asking questions is worth ticking eagerly anyway.
    ///
    /// Raises the interrupt only on the edge into the window, and only while unattended:
    /// the reader is asleep on a timeout computed earlier, so without it the first notch of
    /// a gesture would get its fast tick up to a second late.
    fn interacted(&self) {
        if self.attended.load(Ordering::Relaxed) {
            return;
        }
        let mut until = self.interacted_until.held();
        let was_interacting = remaining(*until).is_some();
        *until = Some(std::time::Instant::now() + INTERACTION_WINDOW);
        drop(until);
        if !was_interacting {
            self.interrupt.raise();
        }
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

    /// Queue the replies the emulator composed, as [`Term::take_outbound`] hands them over.
    fn queue_replies(&self, outbound: Vec<Event>) {
        if outbound.is_empty() {
            return;
        }
        let mut queue = self.replies.held();
        for event in outbound {
            match event {
                Event::Reply(bytes) => queue.push(ReplyKind::Answer, &bytes),
                Event::SizeReport(bytes) => queue.push(ReplyKind::SizeReport, &bytes),
                _ => continue,
            };
        }
    }

    /// Offer the queued replies to the pty without waiting, answering whether any are still
    /// waiting for room.
    ///
    /// Leaves the queue alone while [`Session::send`] holds the writer, since the sender
    /// offers the queue again before it lets go, and answers `false` then: nothing need
    /// watch for room on the sender's behalf. A write that fails outright empties the
    /// queue, because the child is gone; the reader learns that from its own read.
    fn flush_replies(&self) -> bool {
        let writer = match self.writer.try_lock() {
            Ok(writer) => writer,
            Err(TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(TryLockError::WouldBlock) => return false,
        };
        let mut queue = self.replies.held();
        let _ = queue.flush(|bytes| self.pty.write_some(bytes));
        drop(writer);
        !queue.is_empty()
    }

    /// Whether the reader should watch the pty for room: replies are waiting, and no
    /// sender is about to write them itself.
    fn awaits_room(&self) -> bool {
        !self.replies.held().is_empty()
            && !matches!(self.writer.try_lock(), Err(TryLockError::WouldBlock))
    }

    /// [`Session::send`]'s write, after the replies queued ahead of it.
    fn write_after_replies(&self, bytes: &[u8], deadline: std::time::Instant) -> Result<()> {
        loop {
            let mut queue = self.replies.held();
            queue.flush(|b| self.pty.write_some(b))?;
            if queue.is_empty() {
                break;
            }
            drop(queue);
            self.pty.wait_writable(deadline)?;
        }
        self.pty.write(bytes, deadline)
    }

    fn read_loop(&self) {
        block_sigpipe();
        let mut buf = vec![0u8; READ_CHUNK];

        while !self.shutdown.load(Ordering::SeqCst) {
            // Room is watched for only while a reply waits for it: a child that is not
            // reading keeps the pty full, and a writable pty with nothing to write would
            // return from every poll at once.
            let events = if self.awaits_room() {
                PollFlags::POLLIN | PollFlags::POLLOUT
            } else {
                PollFlags::POLLIN
            };
            let mut fds = [
                PollFd::new(self.pty.as_fd(), events),
                PollFd::new(self.interrupt.read.as_fd(), PollFlags::POLLIN),
            ];
            match poll(&mut fds, self.poll_timeout()) {
                Err(nix::errno::Errno::EINTR) => continue,
                Err(_) => break,
                Ok(_) => {}
            }
            let interrupted = fds[1].revents().is_some_and(|r| !r.is_empty());
            let revents = fds[0].revents().unwrap_or(PollFlags::empty());
            let ready = !(revents - PollFlags::POLLOUT).is_empty();
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

            // A resize the tty has not taken yet is retried on every tick; see
            // `Session::resize`.
            self.apply_pending_resize();

            // Before the backlog check below, which stops reading but must not stop the
            // child from getting its answers: a program blocked in `write` may be about to
            // read one.
            if revents.contains(PollFlags::POLLOUT) {
                self.flush_replies();
            }

            // Retires a notification held back by the throttle or the quiescence rule.
            // This, rather than the read below, draws the ordinary frame: a poll that came
            // back with nothing to read is a child that has stopped writing, which is what
            // [`NotifyState::hold`] waits for. The rule lives in `flush` so that `rearm`
            // on Emacs' thread obeys it too.
            self.flush();

            if !ready {
                continue;
            }

            // Backpressure: with a full backlog, leave the bytes in the pty. Its buffer
            // fills and the child blocks in `write`, so output waits instead of being
            // dropped or piling up in memory faster than Emacs can render it.
            if self.term.held().backlog() >= self.backlog_limit.load(Ordering::Relaxed) {
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
                    let (drawable, outbound) = {
                        let mut term = self.term.held();
                        let drawable = if self.hidden.load(Ordering::Relaxed) {
                            term.feed_hidden(data, self.backlog_limit.load(Ordering::Relaxed))
                        } else {
                            term.feed(data)
                        };
                        (drawable, term.take_outbound())
                    };
                    // Answered from here rather than from a drain, so a frozen or hidden
                    // buffer's child is answered too. See `ReplyRoute` for which replies
                    // wait for Lisp instead.
                    self.queue_replies(outbound);
                    self.flush_replies();
                    self.refresh_sync();
                    // Not `announce`: the `flush` at the top of the loop sends the wakeup
                    // once the child has finished writing. Passing whether the read changed
                    // anything drawable matters because most reads of an image transfer do
                    // not, and waking Emacs to repaint an identical grid is wasted work.
                    self.notifier.fed(drawable);
                    // The child has just written, so the tty is worth asking about again
                    // shortly: the prompt of a secret read lands here, and the
                    // `tcsetattr` behind it a fraction of a millisecond later. See
                    // [`RESAMPLE_DELAY`].
                    self.arm_resample();
                    // A child that changes mode almost always writes at the same moment, so
                    // re-sampling here catches the common case at once. A change goes out
                    // without waiting on the frame, because a password prompt is only
                    // useful early.
                    if self.sample_mode() {
                        self.announce();
                    }
                }
                // EIO is how Linux reports the last slave closing.
                Err(e) if e.is(Errno::EIO) => {
                    return self.finish(Ended::ChildGone);
                }
                // The master is non-blocking, and a poll that reported a hangup or an error
                // can find nothing to read after all.
                Err(e) if e.is(Errno::EINTR) || e.is(Errno::EAGAIN) => {}
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
        // Acknowledged on Emacs' behalf, because a wakeup still in flight would otherwise
        // swallow the one below, which is the last this session sends. Not `rearm`: the
        // byte goes out regardless of the throttle.
        self.notifier.acknowledge();
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
        // `ENOTTY` is the transient this exists for (macOS, before the child opens the
        // slave) and is worth retrying. Any other error will not change by asking again, so
        // give up on this size rather than repeating the ioctl on every poll.
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
    use crate::emu::{self, CellMetrics, Event};
    use nix::errno::Errno;
    use nix::fcntl::{FcntlArg, FdFlag, fcntl};
    use std::time::{Duration, Instant};

    /// `kill(pid, 0)` only probes for existence. ESRCH means the pid is gone for good.
    fn alive(pid: i32) -> nix::Result<()> {
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None)
    }

    /// Close-on-exec, because these tests fork children concurrently, and an inheritable
    /// read end would show up in `the_child_inherits_only_stdio` as a leak.
    ///
    /// Not `crate::platform::cloexec_pipe`, which also sets `O_NONBLOCK` and these tests
    /// read blockingly, and not `pipe2`, which macOS lacks.
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
    /// Nonblocking, because a blocking read cannot tell the notification a test is about
    /// from the one [`Shared::finish`] writes when the child exits: it waits, the child's
    /// `sleep` ends, and the assertion passes on the wrong byte. A test written that way
    /// stays green with the path it names deleted.
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

    /// A deadline of `seconds`, stretched by [`crate::pty::timeout_scale`].
    fn patience(seconds: f64) -> Duration {
        Duration::from_secs_f64(seconds * crate::pty::timeout_scale())
    }

    fn wait_for(session: &Session, done: impl FnMut(&Update) -> bool) -> Update {
        wait_for_within(session, 5.0, done)
    }

    /// [`wait_for`] with the base deadline spelled out, for a test whose child does not
    /// begin producing output the moment it starts.
    fn wait_for_within(
        session: &Session,
        seconds: f64,
        mut done: impl FnMut(&Update) -> bool,
    ) -> Update {
        let deadline = Instant::now() + patience(seconds);
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
            .flat_map(|row| row.runs.iter().map(|r| r.text.clone()))
            .collect()
    }

    /// The same promise for pictures. A child drawing images scrolls nothing and raises no
    /// events, so without weighing the payload its backlog would stay at zero however many
    /// megabytes were queued, and the reader would never stop pulling.
    ///
    /// Each picture is *distinct* and each is placed where the last one is not, so none
    /// of them can be shed: they are all still on the grid and all genuinely owed to
    /// Emacs. That is deliberately the case shedding cannot help with, which is the case
    /// backpressure is for.
    #[test]
    fn a_picture_child_is_throttled_and_loses_no_pictures() {
        const FRAMES: usize = 8;
        // 128x64 RGB is 24_576 bytes, 32KB of base64, so a 64KB read carries one or two
        // of them. Small pictures would pack many complete transmissions into a single
        // read and the reader would only stall *after* handling them all, which measures
        // nothing. The payload is doubled up in the shell rather than written out here
        // because eight 32KB arguments is past `ARG_MAX`.
        //
        // Every group is `BwcH` but the first, which varies: ids are content-addressed,
        // so eight copies of one picture are one picture, and the test would pass on a
        // single transmission. Each goes on its own line, so nothing overdraws anything
        // and none of them can be shed -- all eight are on the grid and all are owed to
        // Emacs, which is deliberately the case shedding cannot help with and so the one
        // backpressure exists for.
        let script = r#"
            p=BwcH
            i=0; while [ $i -lt 13 ]; do p=$p$p; i=$((i+1)); done
            q=${p#????}
            for c in A B C D E F G H; do
              printf '\033_Ga=T,f=24,s=128,v=64,c=1,r=1;%swcH%s\033\\\n' "$c" "$q"
            done
        "#;
        // A limit of 1 stalls the reader on any queued picture at all, which is the
        // harshest version of the promise.
        let (session, _read) = session_with_backlog(&["/bin/sh", "-c", script], 1);

        // Nothing drains, so nothing may be read past the first picture or two. Weighed,
        // the backlog is over its limit and the reader stops; the child fills the pty
        // buffer and blocks in `write`, which is what being throttled *is*. Unweighed, a
        // picture child raised a backlog of exactly zero -- it scrolls nothing and sends
        // no events -- so the reader took all 256KB as fast as `sh` could write it and
        // the child ran to completion. Still being alive is the observable difference.
        std::thread::sleep(Duration::from_millis(300));
        assert!(
            session.alive(),
            "the child was never throttled: it wrote every picture and exited"
        );

        // ...and throttling must cost nothing but time. Every picture is still owed.
        let mut seen = 0usize;
        let deadline = Instant::now() + patience(20.0);
        while Instant::now() < deadline {
            seen += session.drain().delta.images.len();
            if seen >= FRAMES {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            seen, FRAMES,
            "backpressure dropped pictures instead of stalling the child"
        );
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
        let deadline = Instant::now() + patience(10.0);
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
        // The child outlives the assertion on purpose: if it exited at once, the byte seen
        // could be the one `finish` sends for the exit rather than the one output earns.
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
        std::thread::sleep(emu::term::SYNC_TIMEOUT + Duration::from_millis(120));
        // A short patience rather than none, for scheduling slop -- but bounded well
        // under the child's own `sleep 5`, since a blocking read here would have been
        // satisfied by the byte that the child's *exit* sends and passed regardless.
        assert!(
            woke_within(&read, Duration::from_millis(200)),
            "the held frame must be drawn once the cap expires"
        );
        drop(session);
    }

    /// Noise is not a reason to hold a frame forever.
    ///
    /// [`QUIESCENCE`] waits for the pty to go quiet, and every read refreshes that wait —
    /// including the reads that change nothing, which is deliberate: `viu` sends a cursor
    /// move, then megabytes of image, then a newline, and the picture is what the wait is
    /// for. [`NotifyState::frame_ceiling`] bounds the wait for a client that keeps
    /// *changing* the screen, but it is armed by a second drawable change, so a client
    /// whose noise is never drawable arms nothing and renews the hold on every read.
    ///
    /// The real case is a child that prints one line and then writes `ESC [ 0 m` flat out,
    /// where every read after the first changes nothing drawable. It is driven through the
    /// notifier rather than through that child because whether the line and the noise land
    /// in one read depends on the reader's chunking.
    #[test]
    fn noise_from_a_client_cannot_hold_a_drawn_frame_back() {
        let (read, write) = pipe();
        let notifier = Notifier::new(write, &Options::default());
        // One drawable change -- the frame -- and then nothing but reads.
        notifier.fed(true);
        let start = Instant::now();
        let mut held_for = None;
        while start.elapsed() < HOLD_CEILING * 2 {
            notifier.fed(false);
            notifier.flush();
            if woke_within(&read, Duration::ZERO) {
                held_for = Some(start.elapsed());
                break;
            }
            // Closer together than `QUIESCENCE`, which is what makes the pty never quiet.
            std::thread::sleep(QUIESCENCE / 2);
        }
        let held_for = held_for.unwrap_or_else(|| {
            panic!(
                "a client writing nothing drawable held its one drawn frame for the whole \
                 of {:?}; the hold must be bounded from the frame's first change, not \
                 from the last read",
                start.elapsed()
            )
        });
        assert!(
            held_for < HOLD_CEILING + Duration::from_millis(50),
            "the frame was held {held_for:?}, past the {HOLD_CEILING:?} backstop"
        );
    }

    /// A client that never stops starting frames must still be drawn.
    ///
    /// [`SYNC_TIMEOUT`] is armed by the emulator at every BSU, so a client that begins its
    /// next frame before the last was drawn -- a full-screen program repainting under a
    /// stream of wheel notches -- would renew the hold on every read and stop the buffer
    /// updating.
    ///
    /// Driven through the notifier in the read loop's own order -- feed, copy the
    /// emulator's deadline, flush -- rather than through a child, because whether a real
    /// child reproduces it depends on how its writes fall across the reader's chunks. The
    /// invariant asserted is that a marker renewed on every read may not move the deadline
    /// the first one set.
    #[test]
    fn a_renewed_sync_marker_cannot_push_a_held_frame_past_its_cap() {
        let (read, write) = pipe();
        let notifier = Notifier::new(write, &Options::default());
        let start = Instant::now();
        let mut held_for = None;
        // Twice the cap: long enough that a deadline being renewed never expires inside
        // it, short enough to fail quickly when one is.
        while start.elapsed() < emu::term::SYNC_TIMEOUT * 2 {
            // A read that is drawable, is inside a frame, and begins another one.
            notifier.fed(true);
            notifier.set_sync(Some(Instant::now() + emu::term::SYNC_TIMEOUT));
            notifier.flush();
            if woke_within(&read, Duration::ZERO) {
                held_for = Some(start.elapsed());
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let held_for = held_for.unwrap_or_else(|| {
            panic!(
                "a client that kept beginning frames held the buffer for the whole of \
                 {:?} and was never drawn",
                start.elapsed()
            )
        });
        assert!(
            held_for < emu::term::SYNC_TIMEOUT + Duration::from_millis(50),
            "the frame was held {held_for:?}, past the {:?} cap its first marker set; a \
             later marker must leave that deadline where it is",
            emu::term::SYNC_TIMEOUT
        );
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
        /// [`Notifier::rearm`] asks for can cut that short.
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
            Options::with_min_redisplay_interval(THROTTLED),
        );
        let mut byte = [0u8; 1];
        nix::unistd::read(read.as_fd(), &mut byte).expect("first wake");

        // Draining and then declaring ourselves ready is the whole of what Emacs' filter
        // does around a redisplay: no second wakeup can follow while the first is still in
        // flight, so without the pair the second wake would just be the first
        // notification's own byte. Releasing the write is what makes there be something to
        // hold back.
        match when {
            Drain::BeforeTheWrite => {
                session.drain();
                session.ready();
                session.send(b"\n").expect("release the second write");
            }
            Drain::AfterTheWrite => {
                session.send(b"\n").expect("release the second write");
                // Long enough that the write is certainly in, short enough that the re-arm
                // still lands inside the throttle window -- outside it there is nothing
                // held back, because `ready`'s own flush sends the byte on the spot.
                std::thread::sleep(THROTTLED / 4);
                session.drain();
                session.ready();
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

    /// The interval reaches a session already running, and takes the frame ceiling with
    /// it.
    ///
    /// The pair is the point. `frame_ceiling` is not a parameter anywhere on this path --
    /// it is derived from the interval by the same constructor `spawn` goes through -- so
    /// this asserts that a session set to a new interval holds a frame by the new one too,
    /// rather than by whatever it was spawned with. Reading them back through the lock is
    /// the whole test: what could go wrong is one of the two being left behind.
    #[test]
    fn set_tuning_moves_the_interval_and_the_ceiling_together() {
        let (session, _read) = session_with(
            &["/bin/sh", "-c", "sleep 5"],
            Options::with_min_redisplay_interval(Duration::from_millis(8)),
        );

        {
            let state = session.shared.notifier.state.held();
            assert_eq!(state.min_interval, Duration::from_millis(8));
            assert_eq!(state.frame_ceiling, Duration::from_millis(8));
        }

        session.set_tuning(Duration::from_millis(40), 99);

        let state = session.shared.notifier.state.held();
        assert_eq!(state.min_interval, Duration::from_millis(40));
        assert_eq!(
            state.frame_ceiling,
            Duration::from_millis(40),
            "the ceiling stayed at the interval the session was spawned with"
        );
        drop(state);
        assert_eq!(
            session.shared.backlog_limit.load(Ordering::Relaxed),
            99,
            "the backlog limit is set by the same call and was not"
        );
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

    /// The quiescence window the two tests below run at, hugely above its 500us default,
    /// with the redisplay floor taken out from under it.
    ///
    /// Half a millisecond is not a gap a shell can be asked to produce or to avoid: a
    /// `sleep 0.0005` is rounding error against process scheduling, and two `printf`s in a
    /// row are usually one read anyway. Widening the window to something a `sleep` can
    /// straddle is what makes the child's writes land on the side of it the test names.
    /// It has to stay under `POLL_TIMEOUT_MS` (100ms) so a wakeup cannot be attributed to
    /// the tick, and `min_redisplay_interval` goes down to 1ms so the floor is never the
    /// thing under measurement.
    const QUIET: Duration = Duration::from_millis(60);

    fn quiescent_session(script: &str) -> (Session, OwnedFd) {
        session_with(
            &["/bin/sh", "-c", script],
            Options {
                min_redisplay_interval: Duration::from_millis(1),
                quiescence: QUIET,
                ..Options::default()
            },
        )
    }

    /// Two writes closer together than the quiescence window are one frame, and one frame
    /// is one wakeup: the first byte Emacs ever hears about already carries both.
    ///
    /// This is the whole of the flicker fix. `viu` writes a cursor move, then four
    /// megabytes of image, then a newline, and drawing between the first and the last
    /// paints the cursor at the top of a picture that has not arrived — every frame, at
    /// 7Hz. The gap here stands in for the transfer.
    #[test]
    fn writes_inside_the_quiescence_window_are_one_wakeup() {
        let (session, read) = quiescent_session("printf a; sleep 0.02; printf b; sleep 5");
        assert!(
            woke_within(&read, Duration::from_secs(2)),
            "the frame was never drawn at all"
        );
        assert_eq!(
            rendered(&session.drain()).trim(),
            "ab",
            "the first wakeup must carry the whole of what the child wrote"
        );
        drop(session);
    }

    /// And two writes further apart than the window are two frames, so the first is drawn
    /// without waiting on the second. A rule that coalesced everything would be a rule
    /// that made the terminal feel slow.
    #[test]
    fn writes_outside_the_quiescence_window_are_two_wakeups() {
        let (session, read) = quiescent_session("printf a; sleep 0.4; printf b; sleep 5");
        assert!(
            woke_within(&read, Duration::from_secs(2)),
            "the first write was never drawn"
        );
        assert_eq!(
            rendered(&session.drain()).trim(),
            "a",
            "the child had gone quiet; the first write must not wait on the second"
        );
        // Drained and re-armed, exactly as Emacs' filter does around a redisplay, so there
        // is a second byte to be had rather than the first one's own.
        session.ready();
        assert!(
            woke_within(&read, Duration::from_secs(2)),
            "the second write was never drawn"
        );
        drop(session);
    }

    /// A child that never stops writing never goes quiet, so something else has to draw
    /// the frame: [`Notifier::frame_ceiling`], armed at the frame's second change.
    ///
    /// The loop overwrites one column rather than printing lines, so nothing scrolls and
    /// `backlog_limit` — which forces a wakeup of its own — cannot be what passes this.
    /// Bounded rather than infinite so it dies on its own if the teardown below ever
    /// stops working, and bounded well past the patience below so that the byte this
    /// waits for cannot be the one the child's own exit sends.
    #[test]
    fn a_child_that_never_pauses_is_drawn_at_the_ceiling() {
        let (session, read) = session_with(
            &[
                "/bin/sh",
                "-c",
                "i=0; while [ $i -lt 2000000 ]; do printf 'x\r'; i=$((i+1)); done",
            ],
            Options {
                // Far past anything the child will give us, so a pass cannot be the
                // quiescence rule releasing the frame.
                quiescence: Duration::from_secs(30),
                frame_ceiling: Duration::from_millis(20),
                ..Options::default()
            },
        );
        // Settle first, then drain: the shell's own start-up moves the termios, and a
        // mode change is announced rather than held (see `Notifier::announce`), so the
        // first byte on this pipe is not the one this test is about. Draining and
        // re-arming is what Emacs' filter does around a redisplay, and what leaves a
        // second byte to be earned -- by the ceiling alone, since the child has not paused
        // since.
        std::thread::sleep(Duration::from_millis(50));
        session.drain();
        session.ready();
        assert!(
            woke_within(&read, Duration::from_millis(300)),
            "a frame held for a child that never pauses must be drawn at the ceiling"
        );
        drop(session);
    }

    /// The backpressure window ends at [`Session::ready`] and not at [`Session::drain_with`]:
    /// a drain that took a delta buys no second wake byte until Emacs says it has drawn
    /// the first.
    ///
    /// This is the ordering the protocol rests on: if `drain` flushed, the window would
    /// cover taking the delta rather than rendering it, which is what
    /// `min_redisplay_interval` paces.
    ///
    /// Unattended, so the reader's own tick is [`UNATTENDED_POLL_TIMEOUT`] away rather than
    /// [`POLL_TIMEOUT_MS`]: the tick flushes unconditionally and would otherwise send the
    /// byte inside the patience below, which must not be mistaken for the re-arm. The
    /// second write is driven by input rather than a sleep so it cannot land before the
    /// first wakeup has been read.
    ///
    /// The wait after that input is what buys the long tick back, and is the one part of
    /// this that is arithmetic rather than protocol: input restores the eager tick for
    /// [`INTERACTION_WINDOW`] (see [`Shared::interacted`]), so the drain has to happen
    /// after that has expired *and* after the reader has computed a fresh timeout past
    /// it, or the 100ms tick lands inside the patience below and is read as the drain
    /// having flushed. Past [`RESAMPLE_DELAY`] by construction, so no armed resample is
    /// left to bring a tick forward either. Nothing can escape onto the pipe during the
    /// wait: every path to the wake descriptor is gated on `notified`, which only the
    /// drain below clears.
    #[test]
    fn a_drain_earns_no_second_wakeup_until_ready_says_the_frame_is_drawn() {
        let (session, read) = session_with(
            &[
                "/bin/sh",
                "-c",
                "printf 'first\n'; read -r _; printf 'second\n'; sleep 5",
            ],
            Options::default(),
        );
        session.set_attended(false);
        assert!(
            woke_within(&read, Duration::from_secs(2)),
            "the first write was never announced at all"
        );

        session.send(b"\n").expect("release the second write");
        // The window itself, plus a couple of eager ticks' slack for the reader to have
        // settled back onto the long one.
        std::thread::sleep(INTERACTION_WINDOW + Duration::from_millis(250));
        session.drain();
        assert!(
            !woke_within(&read, Duration::from_millis(200)),
            "the second write was announced by the drain itself; the re-arm belongs to \
             `ready`, after Emacs has rendered"
        );

        session.ready();
        assert!(
            woke_within(&read, Duration::from_millis(500)),
            "`ready` must release the notification the drain deliberately withheld"
        );
        drop(session);
    }

    /// Output that only changes a hidden buffer's screen wakes nobody, and showing the
    /// buffer again wakes Emacs for it. See [`Term::feed_hidden`] and
    /// [`Session::set_hidden`].
    ///
    /// The child writes only once told to, so the drain before that has emptied whatever
    /// its start-up left, and the silence after it is the gate and not an empty pty.
    #[test]
    fn a_hidden_session_holds_screen_output_until_it_is_shown() {
        let (session, read) = session_with(
            &["/bin/sh", "-c", "read -r _; printf 'text\\n'; sleep 5"],
            Options::default(),
        );
        session.set_hidden(true);
        std::thread::sleep(Duration::from_millis(100));
        session.drain();
        session.ready();
        let _ = woke_within(&read, Duration::from_millis(100));

        session.send(b"\n").expect("release the write");
        assert!(
            !woke_within(&read, Duration::from_millis(300)),
            "a hidden session woke Emacs for text on its screen"
        );
        session.set_hidden(false);
        assert!(
            woke_within(&read, Duration::from_millis(300)),
            "showing the session did not wake Emacs for the output it held"
        );
        assert!(rendered(&session.drain()).contains("text"));
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

    /// The stretch is a stretch and not a stop: a silent mode change is still noticed
    /// while unattended, just later. Worth pinning because "nobody is looking" is a
    /// reason to ask less often and never a reason to stop parsing or stop sampling,
    /// and an infinite timeout would pass every other test in this file.
    #[test]
    fn an_unattended_session_still_observes_a_silent_mode_change() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 0.2; stty -echo; sleep 5"]);
        session.set_attended(false);
        assert_eq!(session.mode(), Mode::Cooked);
        // Generously past `UNATTENDED_POLL_TIMEOUT`; the assertion is that it arrives at
        // all, not when. `wait_for` polls `Session::mode`, which is the reader thread's
        // cached sample rather than a fresh `tcgetattr`, so nothing here can observe the
        // transition except the tick under test.
        let update = wait_for(&session, |u| u.mode == Mode::Secret);
        assert_eq!(update.mode, Mode::Secret);
    }

    /// Regaining attention must not leave the reader asleep for the rest of a long poll.
    ///
    /// This is the whole reason `set_attended` raises the interrupt. Without it the
    /// child's `stty` below is noticed on whatever remains of a one-second tick that
    /// began before the buffer came back — up to a second of the exact staleness the
    /// stretch was only ever allowed to have while nobody could be hurt by it.
    #[test]
    fn regaining_attention_interrupts_the_long_poll() {
        let (session, _read) = session(&["/bin/sh", "-c", "stty -echo; sleep 5"]);
        session.set_attended(false);
        // Long enough to be certainly inside a fresh unattended poll, and far short of
        // its one-second expiry, so a pass cannot be the tick expiring on its own.
        std::thread::sleep(Duration::from_millis(250));
        let start = Instant::now();
        session.set_attended(true);
        let update = wait_for(&session, |u| u.mode == Mode::Secret);
        assert_eq!(update.mode, Mode::Secret);
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_millis(300),
            "took {elapsed:?} to notice the mode after attention returned; expected the \
             interrupt to wake the reader, not the rest of a 1s unattended tick"
        );
    }

    /// Input restores the eager tick to a session nobody is looking at, and does it
    /// without waiting out the long poll already in progress.
    ///
    /// The gesture this is written for is a wheel notch over an unselected terminal:
    /// `cooked-mouse-event` forwards it to the child without selecting the window, so the
    /// session is being used and unattended at the same time, and everything the stretch
    /// was allowed to make stale is what the next notch depends on. Same shape as
    /// `regaining_attention_interrupts_the_long_poll`, and the same 250ms of settling
    /// first so a pass cannot be the unattended tick expiring on its own — but nothing
    /// here tells the session anyone is looking, because in the case it stands in for,
    /// nobody is.
    #[test]
    fn input_restores_the_eager_tick_to_an_unattended_session() {
        // Raw first so the write below cannot be echoed: the mode change has to be
        // noticed by the tick under test rather than announced by output the child made
        // out of the very byte that is supposed to have bought the tick.
        let (session, _read) = session(&["/bin/sh", "-c", "stty raw -echo; sleep 5"]);
        session.set_attended(false);
        std::thread::sleep(Duration::from_millis(250));
        let start = Instant::now();
        session.send(b"j").expect("send");
        let update = wait_for(&session, |u| u.mode == Mode::Raw);
        assert_eq!(update.mode, Mode::Raw);
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_millis(300),
            "took {elapsed:?} to notice the mode after input; expected the interaction \
             window to raise the interrupt, not the rest of a 1s unattended tick"
        );
    }

    /// The window is a window: an unattended session that stops being used goes back to
    /// the long tick on its own, with nothing to un-tell it.
    ///
    /// White-box on `base_poll_wait` rather than timed, because what is being asserted is
    /// the decay itself and a timing test for it could only be a sleep watching a tick
    /// that has nothing to do — slow, and green either way on a loaded machine.
    #[test]
    fn the_interaction_window_decays_back_to_the_long_tick() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 5"]);
        session.set_attended(false);
        assert_eq!(
            session.shared.base_poll_wait(),
            UNATTENDED_POLL_TIMEOUT,
            "an unattended session nobody has touched must rest on the long tick"
        );

        session.send(b"j").expect("send");
        assert_eq!(
            session.shared.base_poll_wait(),
            Duration::from_millis(u64::from(POLL_TIMEOUT_MS)),
            "input must buy the eager tick back"
        );

        std::thread::sleep(INTERACTION_WINDOW + Duration::from_millis(50));
        assert_eq!(
            session.shared.base_poll_wait(),
            UNATTENDED_POLL_TIMEOUT,
            "the window must expire on its own once the gesture is over"
        );
    }

    /// Interaction buys the ordinary tick back and never a faster one. There is no
    /// faster one: what paces a session is `min_redisplay_interval` and Emacs' readiness,
    /// and a burst that outran `POLL_TIMEOUT_MS` would be a second pace mechanism.
    #[test]
    fn interaction_never_ticks_faster_than_an_attended_session() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 5"]);
        let attended = session.shared.base_poll_wait();
        session.set_attended(false);
        session.send(b"j").expect("send");
        assert_eq!(session.shared.base_poll_wait(), attended);
    }

    /// Attention changes the tick and nothing else. The pty is read on `POLLIN`, which
    /// no timeout defers, so output must arrive at the same speed either way.
    #[test]
    fn an_unattended_session_still_renders_output_promptly() {
        let (session, _read) = session(&["/bin/cat"]);
        session.set_attended(false);
        let start = Instant::now();
        session.send(b"ping\n").expect("send");
        let update = wait_for(&session, |u| rendered(u).contains("ping"));
        assert!(rendered(&update).contains("ping"));
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_millis(300),
            "took {elapsed:?} for output to reach an unattended session; the poll timeout \
             must not gate reading, only the termios sample"
        );
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
    /// This does *not* cover the interrupt pipe. `sh` dies on the SIGHUP `shutdown` sends,
    /// its side of the pty closes, and the reader's `poll` returns on the pty fd whether or
    /// not anything interrupted it, so the test passes with `Interrupt::raise` removed.
    ///
    /// A child that ignores SIGHUP is what the pipe is for, and no test covers it, because
    /// the saving is a tail -- whatever is left of the current `POLL_TIMEOUT_MS` tick --
    /// that spawn noise swamps. This is a guard against teardown becoming grossly slow.
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
                .any(|e| matches!(e, Event::Mark(crate::emu::Mark::PromptStart, ..)))
        });
        assert!(
            update
                .delta
                .events
                .iter()
                .any(|e| matches!(e, Event::Mark(crate::emu::Mark::PromptEnd, ..)))
        );
    }

    /// The half of mode 2048 the emulator tests cannot see: the report is written to the
    /// pty by the resize itself, with no drain and no Lisp in between. The child takes
    /// its input unbuffered and prints what it read with ESC made visible.
    #[test]
    fn a_size_subscriber_is_told_of_a_resize_in_band() {
        let (session, _read) = session(&[
            "/bin/sh",
            "-c",
            r"stty -icanon -echo; printf '\033[?2048hready\n'; dd bs=1 count=34 2>/dev/null | tr '\033' E",
        ]);
        wait_for(&session, |u| rendered(u).contains("ready"));
        session
            .resize(Winsize {
                rows: 12,
                cols: 40,
                cell: CellMetrics::new(10, 20),
            })
            .expect("resize");
        // The answer to `2048 h` first, sent by the reader as it parsed the request, then
        // the report the resize owes.
        let want = "E[48;24;80;0;0tE[48;12;40;240;400t";
        let update = wait_for(&session, |u| rendered(u).contains(want));
        assert!(rendered(&update).contains(want));
    }

    /// A child in raw mode that has stopped reading, with mode 2048 set, while its window
    /// is dragged. Each report used to be written on Emacs' thread with a three-second
    /// timeout, so once the pty's input queue filled every resize froze Emacs.
    #[test]
    fn a_child_that_never_reads_survives_ten_thousand_resizes() {
        let (session, _read) = session(&[
            "/bin/sh",
            "-c",
            r"stty raw -echo; printf '\033[?2048hready\n'; exec sleep 60",
        ]);
        wait_for(&session, |u| rendered(u).contains("ready"));
        let budget = patience(5.0);
        let started = std::time::Instant::now();
        for n in 0..10_000u16 {
            session
                .resize(Winsize {
                    rows: 24 + n % 2,
                    cols: 80,
                    cell: Default::default(),
                })
                .expect("resize");
            // Checked as it goes, so a regression fails in seconds rather than hours.
            assert!(
                started.elapsed() < budget,
                "{n} resizes took {:?}",
                started.elapsed()
            );
        }
        // Every report still waiting was replaced by the next. What is left is the newest,
        // and at most the rest of one the pty took part of before it filled.
        let queued = session.shared.replies.held().len();
        assert!(queued > 0, "the pty should have filled");
        assert!(
            queued < 2 * b"\x1b[48;25;80;0;0t".len(),
            "{queued} bytes queued"
        );
    }

    /// Queries arriving faster than a child that never reads can take the answers. The
    /// reader keeps reading, so the child finishes writing, and the queue stops growing at
    /// its limit.
    #[test]
    fn a_child_flooding_queries_without_reading_still_finishes_writing() {
        let (session, _read) = session(&[
            "/bin/sh",
            "-c",
            r#"stty raw -echo; yes "$(printf '\033[c')" | head -c 4000000; printf 'done\r\n'; exec sleep 60"#,
        ]);
        wait_for_within(&session, 20.0, |u| rendered(u).contains("done"));
        assert!(session.shared.replies.held().len() <= crate::replies::REPLY_QUEUE_LIMIT);
        assert!(!session.shared.replies.held().is_empty());
    }

    /// The load-sensitive one. Its child sleeps before it says anything, so this is
    /// the only wait here that spends most of its budget before the first byte
    /// arrives -- which is why it is the test that failed at a load average of 38
    /// while passing in isolation on the same commit. The extra base budget is for
    /// the child's own sleep; `COOKED_TEST_TIMEOUT_SCALE` is for the machine.
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
        let update = wait_for_within(&session, 10.0, |u| rendered(u).contains("12 40"));
        assert!(rendered(&update).contains("12 40"));
    }
}
