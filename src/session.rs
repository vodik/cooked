//! A running child: pty, emulator, and the reader thread that couples them to Emacs.
//!
//! Emacs' module functions may only be called from the thread holding an `emacs_env`, so
//! the reader never touches Lisp. It parses into the shared [`Term`] and pokes a pipe
//! descriptor obtained from `open_channel`; Emacs' filter then drains on the main thread.

use crate::emu::{ColorScheme, Delta, ImageId, Term};
use crate::error::Result;
use crate::pty::{AtomicMode, JobControl, Mode, Pid, Pty, Winsize};
use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{SigSet, Signal};
use std::ffi::OsStr;
use std::os::fd::{AsFd, OwnedFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
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

/// The same tick, for a session nobody is looking at. See [`Session::set_attended`].
///
/// The trade `POLL_TIMEOUT_MS` refuses to make globally is a bargain when taken only
/// while the buffer is off screen, because the cost of a stale mode is entirely a cost
/// to somebody watching. What the tick buys is noticing a *silent* mode change — one
/// that moves the tty and writes no byte — and the two things that can be done with
/// that knowledge are to raise a password prompt and to swap a keymap. Neither is worth
/// anything to a buffer in no window: nothing is being drawn to read, and no keystroke
/// can arrive without [`Session::sample_mode`] reading the tty first, on the input path,
/// which is the guarantee that does not depend on this tick at all.
///
/// So the mode goes stale while unattended, by design, and is made fresh again the
/// moment attention returns — Emacs forces a sample on the way back in. Ten times fewer
/// wakeups for a session left open in a background buffer, which is most of them, most
/// of the time.
///
/// Bounded rather than infinite, deliberately. `poll` would happily wait forever and the
/// power win would be marginally larger, but three things ride on this loop turning over
/// — the pending resize, the throttled-notification retry, and the resample deadline —
/// and while each has its own path that wakes it, an infinite timeout makes the tick a
/// thing that can never be relied on rather than one that is merely slow. A second keeps
/// every existing invariant working at a tenth the rate, which is the whole of the win
/// with none of the new failure modes.
const UNATTENDED_POLL_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(1000);

/// How long input keeps the eager tick on a session nobody is looking at.
///
/// `set_attended` reads "nobody is looking" off which window is selected, which is the
/// right answer for the question it was written for and half an answer to this one: a
/// terminal in an unselected window is still a terminal the user can scroll, and a wheel
/// notch over one is forwarded to the child without the window ever being selected — so
/// the session is interacted with for the whole of a gesture and unattended throughout
/// it. Everything the stretch was allowed to make stale is exactly what that gesture
/// then depends on being fresh, the termios sample above all: `cooked--mouse-state` and
/// the keymap are read from a mode the tick is the only sampler of, and a second of it
/// is a second of the wrong answer to "who owns the keyboard" while the user is asking.
///
/// So input restores the eager tick for this long past the last byte written to the
/// child, and attention is left to mean what it meant. It is a floor coming back up to
/// [`POLL_TIMEOUT_MS`] and never past it: interaction buys back the ordinary tick, not a
/// faster one, because there is no faster one to buy — the pace a session draws at is
/// `min_redisplay_interval` and Emacs' own readiness, neither of which this touches.
///
/// Half a second because it has to span the gaps *within* a gesture rather than the
/// gesture: wheel notches arrive tens of milliseconds apart and a hand pauses between
/// flicks, so anything shorter drops back to the long tick mid-scroll and buys the
/// staleness back one notch later. It costs, at worst, half a second of eager ticking
/// after the last thing anyone did to a buffer they are not looking at.
const INTERACTION_WINDOW: std::time::Duration = std::time::Duration::from_millis(500);

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
/// that wait for a client that keeps *changing* the screen. Neither covers the client that
/// keeps writing without changing anything: every read pushes `last_read` forward, and the
/// ceiling is armed by a second drawable change that never comes, so the hold renews itself
/// for as long as the noise lasts. Measured: a child that prints one line and then writes
/// `ESC [ 0 m` flat out is never drawn at all.
///
/// That the noise is usually meaningful is the reason the wait exists — `viu` sends a
/// cursor move, then four megabytes of image, then a newline, and drawing between them
/// shows a cursor sitting on a picture that has not arrived. So this is a backstop rather
/// than a rule: long enough that an ordinary transfer finishes inside it, short enough that
/// nobody watching calls it a freeze.
///
/// [`SYNC_TIMEOUT`](crate::emu::term::SYNC_TIMEOUT) exactly, because it is the same promise made
/// to a different client. A client that speaks DEC mode 2026 may hold the frame for 150ms
/// and is then drawn regardless; a client that merely keeps writing gets the same 150ms and
/// the same answer. One number for "how long anything may hold the buffer still", rather
/// than two that would drift.
const HOLD_CEILING: std::time::Duration = crate::emu::term::SYNC_TIMEOUT;

/// A snapshot handed to Lisp on each drain.
pub(crate) struct Update {
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
    /// See [`QUIESCENCE`].
    quiescence: std::time::Duration,
}

struct NotifyState {
    /// Floor on how often the wake pipe is written to, regardless of how fast output
    /// arrives. Without one, a program that rewrites the same line rapidly — a spinner, a
    /// progress meter — drives one full Emacs redisplay per write, which is a lot more
    /// redraws than any of them are actually meant to be seen at and shows up as flicker.
    /// A floor and not a frame clock: it says how close together two wakeups may be, and
    /// nothing about which moment between them is worth drawing. That second question is
    /// [`Self::hold`]'s, and the two are independent — a keystroke echoed after a
    /// quiet second passes both on the spot, while a spinner rewriting its line at 1kHz
    /// is quiet between every write and is held here regardless.
    ///
    /// `Term` always holds the latest state regardless of whether a wakeup was sent for
    /// it, and [`Notifier::flush`] is retried every reader-thread tick — see
    /// [`Notifier::poll_wait`], which shortens that tick to this interval's own
    /// remaining window rather than leaving a throttled notification to wait out the
    /// coarser `POLL_TIMEOUT_MS`.
    ///
    /// In here rather than on [`Notifier`] because it is not a constant: Emacs may set
    /// `cooked-min-redisplay-interval' on a session already running, and every reader of
    /// this already holds this lock. Under it, the interval and the `last` it is compared
    /// against cannot be read from either side of a change.
    min_interval: std::time::Duration,
    /// How long a frame may be held while the child keeps changing it; see
    /// [`Self::hold`].
    ///
    /// One `min_interval`, *derived* from it by [`Options::with_min_redisplay_interval`]
    /// rather than chosen beside it, because the two compose rather than add: [`Notifier::flush`]
    /// consults the throttle before the hold, so what a continuously-writing child is
    /// actually redrawn at is the longer of the pair. A second, independent number can
    /// therefore only be dead weight (below the interval), or a floor overruling a user who
    /// asked for a faster one — which is what a hardcoded 8333us silently was, exactly
    /// right at the 8ms default and wrong either side of it. Derived, the rule is one
    /// sentence with one number behind it: a held frame is never held longer than one
    /// redisplay interval. The 8ms default makes that half a 60Hz frame, which is foot's
    /// `delayed-render-time-upper`.
    ///
    /// Without a ceiling at all, a child that writes continuously — a full-screen program
    /// repainting flat out — never gives [`QUIESCENCE`] the gap it waits for, and the
    /// buffer would stop updating for as long as it kept that up. `backlog_limit` catches
    /// the same shape only when the output scrolls; an alternate-screen repaint archives
    /// nothing and would sail past it.
    ///
    /// Armed at the *second* change of a held frame rather than the first, which is the
    /// whole difference between this and a plain deadline, and is what makes the rule work
    /// on the case it was written for. One cursor move followed by a long silent transfer
    /// has nothing further to show: firing here would draw the cursor at the top of a
    /// picture that has not arrived yet, hold it there for the rest of the transfer, and
    /// reproduce the flicker at a lower rate. A client that is genuinely streaming changes
    /// has produced its second one within microseconds, so it arms this immediately and is
    /// then redrawn at the redisplay interval throughout.
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
    /// The quiescence rule, and the only policy in the tree that waits for a *client* to
    /// finish rather than for the clock. It is the same shape as DEC mode 2026 — hold the
    /// frame, keep `dirty` set, retire at a deadline — with the pty going quiet standing
    /// in for the child's cooperation, which is what makes it work for the overwhelming
    /// majority of clients that will never emit a 2026 sequence in their lives.
    ///
    /// Two deadlines, whichever comes first: [`QUIESCENCE`] since the last byte arrived,
    /// and [`Self::frame_ceiling`] since the frame's second change. `last_read` unset — which
    /// [`Notifier::announce`] arranges — means there is nothing to wait for at all.
    fn hold(&self, quiescence: std::time::Duration) -> Option<std::time::Duration> {
        let mut wait = remaining(self.last_read.map(|t| t + quiescence))?;
        // `None` from either deadline below is one that has *passed*, and so a release
        // rather than an absent deadline. The two spell the same in `Option` and mean
        // opposite things, which is why each is asked for separately rather than folded
        // into the `min` with a default.
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
    /// Nothing is retired or rescheduled. A frame already being held keeps the deadline
    /// it was given -- at most one old interval late, by a change the user made by hand --
    /// and every frame after it is held by the new one. Recomputing `ceiling_at` here
    /// would be the tidier-looking option and is wrong: it would let a user dragging a
    /// customize slider repeatedly re-arm the hold on a frame that was ready to draw.
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
    /// Clearing both quiescence deadlines is what "not part of a frame" means here. A
    /// termios change, a full backlog and a child that has exited are none of them things
    /// the child is going to finish writing, and the one case that matters — `getpass`
    /// turning echo off a fraction of a millisecond after printing its prompt — is
    /// precisely one that must not wait on the rest of an update.
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
                // The first change of a frame: what [`HOLD_CEILING`] is measured from, and
                // the only thing armed here, because one change is not yet evidence that
                // more are coming -- which is the whole difference between this and
                // `ceiling_at`.
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
    /// Only half of what a drain used to do, and the half that says nothing about when
    /// the next byte may go out: the acknowledgement is separated from the re-arm because
    /// the two belong at opposite ends of Emacs' work. Taking a delta is cheap; *drawing*
    /// it is the whole cost of a frame — 0.16ms of it for plain text and 11.9ms for box
    /// drawing, measured — and re-arming here would end the backpressure window before
    /// any of that had happened. `min_interval` would then have elapsed by the time the
    /// render finished on every workload it exists to throttle, which is a floor that
    /// never engages. [`Self::rearm`] is the other half, and Lisp calls it when the
    /// buffer is drawn.
    fn acknowledge(&self) {
        self.notified.store(false, Ordering::SeqCst);
    }

    /// Emacs has finished drawing, so the next change is worth another byte.
    ///
    /// Returns whether a throttled notification is still waiting. Flushing here retires
    /// the ordinary case, where the render lands after `min_interval` has already elapsed.
    /// A re-arm that lands inside the window leaves the retry to the reader thread — which
    /// computed its [`Self::poll_timeout`] while the previous wakeup was still in flight,
    /// and so is asleep for the whole of `POLL_TIMEOUT_MS` rather than for the few
    /// milliseconds this notification actually has left to wait. That is the caller's cue
    /// to interrupt the poll so the timeout is computed again.
    fn rearm(&self) -> bool {
        self.flush();
        self.dirty.load(Ordering::SeqCst) && !self.notified.load(Ordering::SeqCst)
    }

    /// Copy the emulator's synchronized-output deadline where the notify path can see it.
    ///
    /// Adopted only when no frame is being held by an earlier one, which is the whole of
    /// what stops a client from holding the buffer still indefinitely. [`SYNC_TIMEOUT`]
    /// is armed by the emulator at every BSU, so taking the newest deadline each time
    /// makes the cap a per-marker one: a client that begins its next frame before the
    /// reader has drawn the last — which is every client repainting flat out, and is
    /// exactly what a full-screen program under a stream of wheel notches does — pushes
    /// the deadline out by another 150ms on every read, and the frame is never drawn at
    /// all. Measured on a child repainting with no gap between frames: 21 wakeups in
    /// three seconds against 152 for the same child without the markers, and stalls of
    /// several seconds in a real session.
    ///
    /// So the first deadline of a held frame is the one that counts, and a later BSU can
    /// only leave it where it is. `None` still clears it on the spot, because that is ESU
    /// — the client saying the frame is finished, which is the one thing that should be
    /// able to shorten the hold. Once a flush clears `dirty` the next BSU is starting a
    /// frame nobody is waiting on, and is adopted as usual.
    ///
    /// The same shape as [`NotifyState::frame_ceiling`], and for the same reason: a hold
    /// that the child can renew is not a hold with a timeout, it is a hold. Both are
    /// bounded from the moment the frame started being held rather than from the last
    /// thing the child said.
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
    /// `base` is the caller's answer for the quiet case, which is [`POLL_TIMEOUT_MS`] or
    /// [`UNATTENDED_POLL_TIMEOUT`] depending on whether anyone is looking. It is a
    /// parameter rather than a field for the same reason [`Shared::poll_timeout`] folds
    /// in the resample deadline from outside: how often the tty is worth asking about is
    /// a termios question, and the notifier has no business knowing about termios. What
    /// it owns is the *other* two deadlines below, which are its own and which override
    /// the base whenever they apply.
    ///
    /// Plenty coarse either way, since real pty data wakes `poll` immediately regardless
    /// of the timeout, and nothing else queued behind it (teardown, a stashed resize, a
    /// termios change) needs finer granularity. But when [`Self::flush`]
    /// has already deferred a notification to `min_interval`'s throttle and the child then
    /// falls quiet, nothing else will wake the loop before that window elapses — so waiting
    /// out the rest of `POLL_TIMEOUT_MS` instead adds up to a hundred extra milliseconds
    /// onto the tail of every burst of output. Invisible on a spinner, which is what the
    /// throttle exists for; felt as a stutter on the last frame of output a mouse wheel
    /// just asked a full-screen program to draw. Shortening the poll to exactly that
    /// remaining window, only while it applies, retires the notification at `min_interval`'s
    /// own cadence instead.
    fn poll_wait(&self, base: std::time::Duration) -> std::time::Duration {
        if self.notified.load(Ordering::SeqCst) || !self.dirty.load(Ordering::SeqCst) {
            return base;
        }
        // One lock for both halves; as two fields it was two, on every tick.
        let state = self.state.held();
        let throttle = state
            .last
            .map(|t| state.min_interval.saturating_sub(t.elapsed()))
            .unwrap_or_default();
        // A frame held by DEC mode 2026 keeps `dirty` set with nothing to flush, so the
        // throttle's own remainder is typically zero — polling on that would spin this
        // thread hot for the length of every frame. Taking the later of the two deadlines
        // both fixes that and retires the sync timeout at the timeout rather than up to a
        // poll late.
        // The quiescence hold joins the same `max` and for the same reason: it too keeps
        // `dirty` set with nothing to flush, so leaving it out would poll on a zero
        // throttle for the length of every frame.
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
    /// accumulate between drains, so this fills sooner. A static relationship between two
    /// numbers the user sets once, not a rate that moves underneath the child: what paces
    /// a session is Emacs' own readiness -- the wake byte is not re-armed until
    /// [`Session::ready`] -- and the interval is only a floor under that. So this is sized
    /// against the slowest cadence those two constants allow, and nothing recomputes it.
    ///
    /// Atomic because Emacs may set `cooked-backlog-limit' on a session already running.
    /// Relaxed: it is a threshold the reader compares its own queue against once per read,
    /// with no other state ordered against it, so the worst a stale read can do is let one
    /// more chunk through before the new limit applies.
    backlog_limit: AtomicUsize,
    shutdown: AtomicBool,
    /// Whether anyone is looking at this session's buffer; see [`Session::set_attended`].
    /// Starts true, so a session Emacs never reports on — a test, a buffer driven from
    /// Lisp — keeps the eager tick it has always had.
    attended: AtomicBool,
    /// When the eager tick, restored by input, stops being owed to an unattended session;
    /// see [`INTERACTION_WINDOW`]. `None` until something is sent to the child.
    ///
    /// A deadline rather than a flag for the reason every other deadline here is one:
    /// nothing has to remember to clear it, so a gesture that ends because the user let
    /// go — which is every gesture — decays on its own rather than leaving the session
    /// eager until the next thing happens to touch it.
    interacted_until: Mutex<Option<std::time::Instant>>,
    interrupt: Interrupt,
    exited: Mutex<Option<i32>>,
}

/// A self-pipe the reader polls alongside the pty, so the two things that can happen
/// while the child is quiet do not have to wait out the poll timeout.
///
/// Teardown is one: without this, every kill blocks Emacs for up to [`POLL_TIMEOUT_MS`],
/// which is the difference between closing a buffer feeling instant and feeling like a
/// stutter. A re-arm that leaves a throttled notification behind is the other; see
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

/// A live child, its emulator, and the reader thread coupling them to Emacs.
///
/// The owned resources sit behind mutexes rather than in plain `Option`s because
/// [`Session::shutdown`] runs through the `&Session` that Emacs' user-pointer hands
/// back — there is never a `&mut` to be had.
/// The tuning knobs [`Session::spawn`] takes, so they arrive named rather than as the
/// last two of seven positional parameters -- and so their defaults live in the [`Default`]
/// impl below, next to the fields they belong to, rather than at the call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Options {
    /// See [`Notifier::min_interval`].
    pub min_redisplay_interval: std::time::Duration,
    /// See [`QUIESCENCE`].
    pub quiescence: std::time::Duration,
    /// See [`Notifier::frame_ceiling`].
    pub frame_ceiling: std::time::Duration,
    /// See [`Shared::backlog_limit`].
    pub backlog_limit: usize,
}

impl Options {
    /// The defaults, with `min_redisplay_interval` set to what the caller asked for and
    /// everything that derives from it following.
    ///
    /// The one way to choose the interval, and the reason there is a constructor here at
    /// all. [`Notifier::frame_ceiling`] is that interval, so a caller writing
    /// `Options { min_redisplay_interval: x, ..Default::default() }` would get the
    /// ceiling computed from the *default* interval and then the interval it belongs to
    /// overwritten underneath it — the derivation silently undone by the update syntax
    /// that looks like it is only setting one field. Going through a function is what
    /// makes the pair impossible to separate: the derived field is written in the same
    /// expression that decides what it derives from.
    pub(crate) fn with_min_redisplay_interval(min_redisplay_interval: std::time::Duration) -> Self {
        Self {
            min_redisplay_interval,
            // A field rather than [`QUIESCENCE`] read directly, and the only caller that
            // sets it is a test: half a millisecond is not a gap a child can be asked to
            // produce on demand, so the tests that pin the rule widen it to something a
            // shell can hit. The same goes for `frame_ceiling`, which a test pins to a
            // value the derivation would not give it. Lisp does not offer either,
            // deliberately — see `cooked-min-redisplay-interval`, which is the one
            // redisplay knob with a taste question behind it.
            quiescence: QUIESCENCE,
            frame_ceiling: min_redisplay_interval,
            backlog_limit: crate::emu::BACKLOG_HIGH_WATER,
        }
    }
}

impl Default for Options {
    fn default() -> Self {
        Self::with_min_redisplay_interval(std::time::Duration::from_millis(8))
    }
}

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
            notifier: Notifier::new(wake, &options),
            resample_at: Mutex::new(None),
            backlog_limit: AtomicUsize::new(options.backlog_limit),
            shutdown: AtomicBool::new(false),
            attended: AtomicBool::new(true),
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
    /// short grace period, then SIGKILL. The escalation is not belt and braces: a child
    /// that ignores SIGHUP — `nohup`, `trap '' HUP`, a detached session leader — otherwise
    /// survives an explicit kill and is never reaped.
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

    /// Collect everything that changed, acknowledging the wakeup that asked for it.
    ///
    /// Acknowledging is not re-arming: the next wake byte waits on [`Session::ready`],
    /// which Emacs calls once it has drawn what this returned. See
    /// [`Notifier::acknowledge`] for why the window covers the render rather than the
    /// collection.
    pub(crate) fn drain(&self) -> Update {
        self.shared.notifier.acknowledge();
        Update {
            delta: self.shared.term.held().drain(),
            mode: self.shared.mode.load(),
            exit: *self.shared.exited.held(),
        }
    }

    /// Emacs has drawn the last drain and will take another wakeup.
    ///
    /// The far end of the backpressure the wake pipe is: one byte is in flight until
    /// this is called, so the child's writes accumulate in [`Term`] — which always holds
    /// the latest state whether or not anyone was told about it — rather than each one
    /// buying a redisplay. Calling it is what makes `min_redisplay_interval` a floor on
    /// the *rendering* rate rather than on the rate deltas are taken at, which is where
    /// the cost is.
    ///
    /// Safe to omit, and the tests and the benchmark do: a session nobody re-arms is
    /// woken by the reader's ordinary tick instead, so it redraws on
    /// [`POLL_TIMEOUT_MS`]'s cadence rather than on its own. Slower, never stuck — which
    /// is the property that makes this a call Lisp may fail to reach without the
    /// terminal freezing, though `cooked--drain-and-apply` makes it in an
    /// `unwind-protect` cleanup all the same.
    pub(crate) fn ready(&self) {
        if self.shared.notifier.rearm() {
            self.shared.interrupt.raise();
        }
    }

    /// Write BYTES to the child, and count that as the user interacting with this
    /// session; see [`Shared::interacted`].
    pub(crate) fn send(&self, bytes: &[u8]) -> Result<()> {
        self.shared.interacted();
        self.shared.pty.write(bytes)
    }

    /// Forget that any of the top row's line is already in Emacs.
    ///
    /// Emacs holds the scrollback, so only Emacs knows when it has thrown it away.
    pub(crate) fn forget_history(&self) {
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
    pub(crate) fn resize(&self, size: Winsize) -> Result<()> {
        {
            let mut term = self.shared.term.held();
            term.resize(size.rows.into(), size.cols.into());
            // Reported together because they change together: a font change moves the
            // cell size and the row and column count in one event.
            term.set_cell_metrics(size.cell);
        }
        *self.shared.pending_resize.held() = Some(size);
        // Wake the reader rather than leaving the retry to its next tick. That tick used
        // to be at most `POLL_TIMEOUT_MS` away, which was near enough to immediate to
        // leave alone; under [`UNATTENDED_POLL_TIMEOUT`] it can be a second, and a
        // resize that lands while the buffer is off screen — a frame resized around it,
        // a window configuration changing underneath — would take that long to converge.
        // A resize is rare and user-driven, so the extra wakeup costs nothing measurable
        // and buys the retry back its old latency in both states.
        self.shared.interrupt.raise();
        match self.shared.pty.resize(size) {
            // Not ours to set yet; the reader thread keeps trying.
            Err(e) if e.is(Errno::ENOTTY) => Ok(()),
            result => result,
        }
    }

    /// Emacs has dropped an image's bytes; see [`Term::forget_image`].
    pub(crate) fn forget_image(&self, id: ImageId) {
        self.shared.term.held().forget_image(id);
    }

    /// Mark the whole screen damaged, so the next drain re-sends it.
    ///
    /// Emacs asks for this when its own idea of the screen region can no longer be
    /// trusted — a redisplay that signalled part-way through leaves the buffer holding
    /// some rows of a drain and not others, and no amount of further deltas repairs
    /// that, because a delta only describes what changed since.
    pub(crate) fn redraw(&self) {
        self.shared.term.held().touch_all();
    }

    /// Remove `count` grid rows starting at `first`, and repaint what moved.
    ///
    /// The one edit the grid accepts from Emacs. It goes through the emulator rather than
    /// Emacs deleting the buffer text itself for the same reason input does: the rows have
    /// one owner, and the drain that follows is the ordinary one.
    pub(crate) fn remove_rows(&self, first: usize, count: usize) {
        self.shared.term.held().remove_rows(first, count);
    }

    /// Drop the grid rows above the prompt; see [`Term::clear_to_prompt`].
    ///
    /// The other edit the grid accepts from Emacs, and the same bargain as
    /// [`Session::remove_rows`]: Emacs asks, the emulator moves the rows, and the drain
    /// that follows is the ordinary one.
    pub(crate) fn clear_to_prompt(&self) -> usize {
        self.shared.term.held().clear_to_prompt()
    }

    /// The reader thread's last sample. Lisp reads this off the drain's `:mode' instead,
    /// so only the tests ask the session directly.
    #[cfg(test)]
    pub(crate) fn mode(&self) -> Mode {
        self.shared.mode.load()
    }

    /// Re-read the child's termios now, rather than reporting the last sample.
    ///
    /// The drain's `:mode' answers from whatever the reader thread last saw, which is as
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
    /// times longer, because the only thing the tick is for is noticing a silent termios
    /// change and there is nobody to tell. Emacs decides what "looking" means — its
    /// `cooked--attention` already answers that for the render freeze — and this only
    /// spends the answer.
    ///
    /// It is not the only thing that sets the tick, and deliberately not: [`Shared::interacted`]
    /// restores the eager one for [`INTERACTION_WINDOW`] whenever anything is sent to the
    /// child, so being unattended is a *resting* state rather than one the user can be
    /// stuck in while scrolling an unselected window. Nothing here has to know about that
    /// — the two are read together in [`Shared::base_poll_wait`] and neither clears the
    /// other.
    ///
    /// Regaining attention raises the interrupt rather than waiting for the long poll
    /// already in progress to expire. Without that, coming back to a buffer would leave
    /// the reader asleep for up to a second before the shorter tick took effect, which
    /// is exactly the moment it matters most and would put the staleness back where it
    /// was taken from. The interrupt costs one byte and the loop's next pass is
    /// unconditional and idempotent, so there is nothing to get wrong by raising it.
    ///
    /// The freshness the mode itself needs on the way back is not this function's to
    /// give: Emacs forces a [`Session::sample_mode`] as it re-enters, so the answer it
    /// acts on is read at that moment rather than inherited from however long the buffer
    /// sat unwatched.
    pub(crate) fn set_attended(&self, attended: bool) {
        if self.shared.attended.swap(attended, Ordering::Relaxed) != attended && attended {
            self.shared.interrupt.raise();
        }
    }

    /// Adopt a new redisplay interval and backlog limit on a session already running.
    ///
    /// Not `set_pacing`, and the distinction is the one thing worth getting right here:
    /// only the interval is a pace. There is exactly one of those, the ceiling derives from
    /// it, and together they are the whole of how fast a session draws.
    ///
    /// The backlog limit is backpressure, which is a different question with a different
    /// answer: not how often to redraw, but how much may pile up while Emacs falls behind
    /// before [`Self::read_loop`] stops taking bytes off the pty -- at which point its
    /// buffer fills and the child blocks in `write`. One paces, the other pauses. Naming
    /// the pair after the half that paces would assert a second pace mechanism that
    /// deliberately does not exist; [`Notifier::set_pacing`] is the one that earns the word.
    ///
    /// They travel together because they are tuned together: a longer interval leaves more
    /// to accumulate between drains, so the queue fills sooner. One call is what stops a
    /// caller setting half of a pair whose relationship is the point.
    ///
    /// `frame_ceiling` is not a third parameter. It is one `min_redisplay_interval` and is
    /// derived here through the same [`Options`] constructor spawn uses, so the rule that
    /// a held frame is never held longer than one redisplay interval cannot be true at
    /// spawn and false after a `setq`. See [`Options::with_min_redisplay_interval`].
    ///
    /// Nothing is woken. A pacing change is the user adjusting a number, not the child
    /// producing output: the reader picks the new values up on its next turn through the
    /// loop, which is at most one poll tick away, and until then the old interval is the
    /// worst that can apply.
    pub(crate) fn set_tuning(&self, min_redisplay_interval: std::time::Duration, backlog_limit: usize) {
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

    /// The last non-blank line — the prompt text for a [`Mode::Secret`] read.
    pub(crate) fn trailing_text(&self) -> Option<String> {
        self.shared.term.held().trailing_text()
    }

    pub(crate) fn bracketed_paste(&self) -> bool {
        self.shared.term.held().bracketed_paste()
    }

    pub(crate) fn focus_events(&self) -> bool {
        self.shared.term.held().focus_events()
    }

    pub(crate) fn alt_scroll(&self) -> bool {
        self.shared.term.held().alt_scroll()
    }

    /// Record Emacs' colour scheme, returning what a mode 2031 subscriber is owed.
    pub(crate) fn set_color_scheme(&self, scheme: ColorScheme) -> Option<Vec<u8>> {
        self.shared.term.held().set_color_scheme(scheme)
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
    /// Combined here rather than inside [`Notifier`] because the two deadlines are about
    /// different things — one is when Emacs next wants drawing, the other is when the tty
    /// is next worth asking about — and folding a termios concern into the notifier would
    /// put it in the one place that has no business knowing about termios at all.
    ///
    /// `min` and not `max`: an earlier deadline is a reason to wake sooner, never later.
    /// [`remaining`] answers `None` once the deadline has passed, so an expired resample
    /// contributes nothing and cannot pin the timeout at zero and spin this thread.
    ///
    /// The unattended stretch is only the *base*, for the same reason: it is the answer
    /// when nothing else is waiting, and every deadline below still cuts it short. A
    /// throttled notification or an armed resample retires on its own schedule whether
    /// or not anyone is watching the buffer it belongs to.
    fn poll_timeout(&self) -> PollTimeout {
        let mut wait = self.notifier.poll_wait(self.base_poll_wait());
        if let Some(left) = remaining(*self.resample_at.held()) {
            wait = wait.min(left);
        }
        PollTimeout::try_from(wait).unwrap_or_else(|_| PollTimeout::from(POLL_TIMEOUT_MS))
    }

    /// How long a quiet tick lasts, which is the whole of what attention changes.
    ///
    /// Two ways to earn the eager tick and they are deliberately different questions:
    /// attention is Emacs saying the buffer is under the user's eyes, and
    /// [`INTERACTION_WINDOW`] is this session saying it was being used regardless — which
    /// a terminal scrolled in an unselected window is, and which attention alone answers
    /// no for.
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
    /// caller has to remember it and no future input path can forget it — the same reason
    /// [`Notifier::flush`] holds the throttle rule rather than each of its callers. The
    /// automatic writes go through it too (a device-status reply, a focus notification):
    /// they are rarer than keystrokes by orders of magnitude, and a session whose child
    /// is asking questions is one worth ticking eagerly anyway.
    ///
    /// Raises the interrupt only on the edge into the window, and only while unattended.
    /// That is where the whole value is: the reader is asleep on a timeout it computed
    /// before any of this happened, so without the interrupt the first notch of a gesture
    /// buys a fast tick that starts up to a second late — and every notch after it would
    /// raise an interrupt the reader has no use for, the tick it would ask for being the
    /// one already running.
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

            // Retires a notification held back earlier, by the throttle or by the
            // quiescence rule. Unconditional, and it is this call rather than the read
            // below that draws the ordinary frame: a poll that came back with nothing to
            // read is a child that has stopped writing, which is exactly what
            // [`NotifyState::hold`] is waiting to hear. The rule lives in `flush` rather
            // than in a condition here so that every caller obeys it — including the
            // `rearm` on Emacs' own thread.
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
                    let drawable = self.term.held().feed(data);
                    self.refresh_sync();
                    // Not `announce`: the wakeup is now the business of the `flush` at the
                    // top of the loop, which sends it once the child has finished what it
                    // is writing. Handing over what the read produced rather than the fact
                    // that there was one is the other half — most reads of an image
                    // transfer change nothing on screen, and waking Emacs to repaint an
                    // identical grid was 55% of the drains a gif player cost us.
                    self.notifier.fed(drawable);
                    // The child has just written, so the tty is worth asking about again
                    // shortly: the prompt of a secret read lands here, and the
                    // `tcsetattr` behind it a fraction of a millisecond later. See
                    // [`RESAMPLE_DELAY`].
                    self.arm_resample();
                    // A child that changes mode almost always writes at the same moment, so
                    // re-sampling here is what makes the common case feel instantaneous. A
                    // change goes out at once rather than waiting on the frame: a password
                    // prompt is the case, and the whole of its value is being early.
                    if self.sample_mode() {
                        self.announce();
                    }
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
        // Acknowledging on the child's behalf, because a wakeup still in flight would
        // otherwise swallow the one below -- and the one below is the last word this
        // session gets. Not `rearm`: whether anything is left throttled is beside the
        // point here, the byte goes out regardless, and this is the reader thread, with
        // nothing to interrupt.
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

    /// The same promise for pictures, which used to be exempt from it. A child drawing
    /// images scrolls nothing and raises no events, so its backlog was zero however many
    /// undrained megabytes it had queued -- `BACKLOG_HIGH_WATER` was unreachable and the
    /// reader never stopped pulling. Weighing the payload is what puts this child under
    /// the same rule as one printing text.
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
        let deadline = Instant::now() + Duration::from_secs(20);
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
    /// Measured against a child that prints one line and then writes `ESC [ 0 m` flat out
    /// — SGR is not part of `Pending`, so every read after the first changes nothing:
    /// zero wakeups in two seconds, against one immediately for the same child falling
    /// silent instead. Driven through the notifier here rather than through that child,
    /// for the reason `a_renewed_sync_marker_cannot_push_a_held_frame_past_its_cap` is:
    /// whether the line and the noise land in the same read is the reader's chunking, and
    /// a test that samples it passes for the wrong reason as often as not.
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
    /// The bug this pins: [`SYNC_TIMEOUT`] is armed by the emulator at every BSU, so a
    /// client that begins its next frame before the reader has drawn the last renews the
    /// hold on every read, and the buffer stops updating for as long as it keeps that up.
    /// Not a hypothetical shape — it is what a full-screen program repainting under a
    /// stream of wheel notches does, and it was measured in a real session as stalls of
    /// several seconds with the child scrolling throughout. Against the same child
    /// without the markers, where [`NotifyState::frame_ceiling`] is the cap, the
    /// difference was 21 wakeups in three seconds against 152.
    ///
    /// Driven through the notifier in the read loop's own order — feed, copy the
    /// emulator's deadline, flush — rather than through a child, because whether a real
    /// child reproduces it depends on where its writes fall relative to the reader's
    /// chunks: the same script stalls for 300ms on this machine and for seconds in a
    /// session, and a test that samples that alignment asserts nothing in particular.
    /// What is being asserted is the invariant underneath: a marker renewed on every read
    /// may not move the deadline the first one set.
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

    /// The backpressure window ends at [`Session::ready`] and not at [`Session::drain`]:
    /// a drain that took a delta buys no second wake byte until Emacs says it has drawn
    /// the first.
    ///
    /// This is the ordering the whole protocol rests on. `drain` used to flush, so the
    /// window covered taking the delta -- microseconds -- rather than rendering it, which
    /// is the 0.16ms to 11.9ms a frame that `min_redisplay_interval` was written to pace.
    /// Anything that put the flush back would leave this test to notice.
    ///
    /// Unattended, so the reader's own tick is [`UNATTENDED_POLL_TIMEOUT`] (one second)
    /// away rather than [`POLL_TIMEOUT_MS`] (100ms): the tick flushes unconditionally and
    /// would otherwise send the byte itself well inside the patience below, which is the
    /// graceful degradation a caller that never re-arms relies on and exactly what must
    /// not be mistaken for the re-arm here. The second write is driven by input rather
    /// than by a sleep so it cannot land before the first wakeup has been read.
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


