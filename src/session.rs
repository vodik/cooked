//! A running child: pty, emulator, and the reader thread that couples them to Emacs.
//!
//! Emacs' module functions may only be called from the thread holding an `emacs_env`, so
//! the reader never touches Lisp. It parses into the shared [`Term`] and pokes a pipe
//! descriptor obtained from `open_channel`; Emacs' filter then drains on the main thread.

use crate::emu::{Delta, Event, Feed, Term};
use crate::error::Result;
use crate::lock::LockExt;
use crate::pty::{
    AtomicMode, HANGUP_GRACE, JobControl, KILL_GRACE, Mode, Pty, WRITE_TIMEOUT, Wait, Winsize,
};
use crate::replies::{ReplyKind, ReplyQueue};
use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags};
use nix::sys::signal::{SigSet, Signal};
use nix::unistd::Pid;
use std::ffi::OsStr;
use std::os::fd::{AsFd, OwnedFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread::JoinHandle;

const READ_CHUNK: usize = 64 * 1024;

/// How much of one read the reader parses before it looks up to see whether Emacs is
/// waiting for the terminal; see [`Shared::feed`].
///
/// The lock is what Emacs' thread waits on for a drain, a resize, a `cooked--feed' or
/// any question put to [`Term`], and before this existed it waited on the parse of a
/// whole [`READ_CHUNK`] -- 64KB, which at the slowest rate the throughput bench measures
/// (12 MB/s, `OSC 133` back to back) is five milliseconds, a third of a redisplay
/// interval, spent by Emacs doing nothing.
///
/// 8KB because the two costs meet there. The check between slices is an atomic load and
/// a bounds test, so eight of them per read is nothing measurable next to parsing 64KB;
/// what a smaller slice would buy is a shorter worst-case wait, and at 8KB that wait is
/// already under a millisecond even for the slowest input above and about 90us for
/// ordinary text. Going to 1KB would multiply the loop overhead eightfold to shave off
/// what nobody can perceive, and it would also cut more parses in two -- see
/// [`Shared::feed`] on why a slice boundary is not free.
const PARSE_SLICE: usize = 8 * 1024;

/// How many times the reader yields its timeslice to let a waiting Emacs thread take the
/// terminal lock before carrying on regardless; see [`Shared::feed`].
///
/// `std::sync::Mutex` is not fair: on Linux it is a futex, and a thread that unlocks and
/// immediately relocks will usually win the race against the waiter it just woke, which
/// would make the whole slicing pointless. So the reader does not merely drop the lock,
/// it waits until the waiter has actually taken it, which [`Waiting`] reports by
/// decrementing.
///
/// Bounded rather than a plain spin, because nothing may make the reader depend on
/// another thread making progress: a waiter that is descheduled for a whole timeslice
/// would otherwise hold the pty unread. Sixteen yields is far more than the handoff
/// takes when the waiter is runnable -- one or two in practice -- and is over in
/// microseconds when it is not.
const HANDOFF_YIELDS: usize = 16;
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
/// the backoff to [`ATTENDED_TICK_CAP`] take the parts of that saving that cost nothing.
const POLL_TIMEOUT_MS: u8 = 100;

/// The longest a quiet tick grows to while somebody is looking; see
/// [`Shared::base_poll_wait`].
///
/// The tick starts at [`POLL_TIMEOUT_MS`] after anything happens and doubles on every
/// tick that finds nothing, so a session in use is sampled as often as it ever was and
/// an idle one costs a wakeup a second rather than ten. A silent termios change -- a
/// program that sleeps and then calls `tcsetattr` with no I/O either side -- is what
/// the tick still exists for, and how urgently it needs noticing decays with the
/// silence around it: most such changes follow output by microseconds and are caught
/// by [`RESAMPLE_DELAY`] before this is consulted at all.
const ATTENDED_TICK_CAP: std::time::Duration = std::time::Duration::from_secs(1);

/// The same cap, for a session nobody is looking at. See [`Session::set_attended`].
///
/// A stale mode only costs somebody watching: noticing a silent mode change buys a
/// password prompt and a keymap swap, and neither is worth anything to a buffer in no
/// window. No keystroke can arrive without [`Session::sample_mode`] reading the tty
/// first, and Emacs forces a sample when attention returns.
///
/// Bounded rather than infinite, because the pending resize, the throttled-notification
/// retry and the resample deadline all ride on this loop turning over. Each has its own
/// wakeup, but an infinite timeout would make the tick something nothing could rely on,
/// where a few seconds keeps every invariant working at a fraction of the rate.
const UNATTENDED_TICK_CAP: std::time::Duration = std::time::Duration::from_secs(4);

/// How many doublings the quiet tick is allowed; past this the cap decides. Six from
/// 100ms is 6.4 seconds, past both caps.
const TICK_DOUBLINGS_MAX: u32 = 6;

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
/// How long to wait for a child that closed the pty to become reapable before settling
/// in for a longer wait on the exit watch; see [`Shared::linger_for_exit`], which is also
/// where this bounds how promptly teardown is noticed.
const REAP_PATIENCE: std::time::Duration = std::time::Duration::from_millis(500);

/// What `exit` holds for a session whose reader gave up on the pty with the child still
/// unreapable: not an exit status, since there is none, but Lisp still needs the session
/// to end. `cooked--on-exit' spells it out. Negative because no `waitpid` status is.
pub(crate) const LOST: i32 = -1;

/// How quiet the pty must go before a frame is drawn; see [`NotifyState::quiescent_until`].
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
/// [`SYNC_TIMEOUT`](crate::emu::term::SYNC_TIMEOUT) exactly -- 150ms, the figure xterm
/// and contour use for mode 2026 and kitty comes within 50ms of -- because a client using
/// that mode is made the same promise, and one number for how long anything may hold the
/// buffer still cannot drift from another.
const HOLD_CEILING: std::time::Duration = crate::emu::term::SYNC_TIMEOUT;

/// How long after a keystroke the first frame that changes the screen may skip
/// `min_interval`; see [`NotifyState::echo`].
///
/// Typing into a session that drew a frame a moment ago otherwise waits out the rest of
/// the interval for its own echo: a key held down against `cat` is echoed 6-7ms late at
/// the 8ms default, every time, because the previous echo is what set the clock. vterm
/// makes the same exception for the same reason, redrawing at once on the first update
/// after `vterm-send-key`.
///
/// Fifty milliseconds is ghostel's number for its own input path, and generous for an
/// echo, which a line editor or a shell writes within a millisecond or two of the key.
/// The window is only an upper bound on how stale a keystroke may be; what keeps it from
/// waiving more than one frame is that the first drawable read takes it.
const ECHO_WINDOW: std::time::Duration = std::time::Duration::from_millis(50);

/// What bytes bound for the child are, as far as the pace is concerned; see
/// [`Session::send`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Input {
    /// A key the user pressed, whose echo is worth drawing without waiting out
    /// `min_interval`; see [`ECHO_WINDOW`].
    Keyboard,
    /// Anything else: a mouse report, a wheel notch turned into cursor keys, a dropped
    /// file. A pointer sweep under mode 1003 writes a report per motion event, and
    /// drawing the reply to each early would be a frame per report.
    Other,
}

/// A snapshot handed to Lisp on each drain.
pub(crate) struct Update {
    pub delta: Delta,
    pub mode: Mode,
    pub exit: Option<i32>,
}

/// Where everything that paces a frame reads the time.
///
/// `Instant::now` in a session, and in a test a clock the test steps by hand. The rules
/// below relate six deadlines to one another, and a test that waits out real milliseconds
/// to watch one of them fire is a test that can be wrong about time -- which is what
/// `COOKED_TEST_TIMEOUT_SCALE` and the load guard exist to paper over. With a clock the
/// test owns, the notifier's tests are step sequences with exact assertions instead.
///
/// A closure rather than a trait because there is one thing to ask and no state to carry,
/// and behind an `Arc` rather than a type parameter because [`Session`] reaches Lisp as a
/// user pointer and has no business saying in its type what kind of clock it keeps.
#[derive(Clone)]
pub(crate) struct Clock(Arc<dyn Fn() -> std::time::Instant + Send + Sync>);

impl Clock {
    fn now(&self) -> std::time::Instant {
        (self.0)()
    }
}

impl Default for Clock {
    fn default() -> Self {
        Self(Arc::new(std::time::Instant::now))
    }
}

/// Spelled out rather than derived, so [`Options`] keeps the `Debug` it had: a closure
/// has none.
impl std::fmt::Debug for Clock {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Clock")
    }
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
    /// See [`Clock`].
    clock: Clock,
}

struct NotifyState {
    /// Floor on how often the wake pipe is written to, however fast output arrives.
    /// Without one, a spinner rewriting its line drives one full Emacs redisplay per write
    /// and shows up as flicker. It says how close together two wakeups may be and nothing
    /// about which moment is worth drawing, which is [`Self::quiescent_until`]'s question.
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
    /// [`Self::ceiling_at`].
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
    /// Adopted at the *second* change of a held frame rather than the first, which is the
    /// second of the two stages [`Self::ceiling_at`] is armed in.
    frame_ceiling: std::time::Duration,
    /// See [`QUIESCENCE`].
    ///
    /// Fixed for the life of a session, and here beside the deadlines it bounds rather
    /// than on [`Notifier`] so that [`Self::decide`] can read the four gates from one
    /// place and needs nothing passed to it but the time.
    quiescence: std::time::Duration,
    /// When the wake pipe was last actually written to, for `min_interval`.
    last: Option<std::time::Instant>,
    /// While set and unexpired, the child is mid-frame under DEC mode 2026 and has asked
    /// not to be drawn yet. Refreshed from `Term` under the lock the reader already holds,
    /// so no path takes an extra one — and never *extended* while the frame it is holding
    /// is still undrawn; see [`Notifier::set_sync`].
    sync_until: Option<std::time::Instant>,
    /// When the child last wrote anything at all, drawable or not; see
    /// [`Self::quiescent_until`].
    ///
    /// Every read moves it, including the ones that changed nothing: a megabyte of image
    /// data changes no cell, and is still the loudest possible evidence that the client
    /// is in the middle of an update.
    last_read: Option<std::time::Instant>,
    /// When the frame being held stops being held, whatever the child does next. `None`
    /// while no frame is held.
    ///
    /// Armed in two stages, because a frame's first change and its second say different
    /// things. The first arms [`HOLD_CEILING`], the outer bound on any hold: one change is
    /// not yet evidence that more are coming, and a lone cursor move followed by a long
    /// silent image transfer must not be drawn over the picture in flight. The second is
    /// that evidence, and brings the deadline in to [`Self::frame_ceiling`], the pace a
    /// busy client is drawn at -- which a client genuinely streaming changes reaches
    /// within microseconds of its first.
    ///
    /// One field rather than the two this was, an outer `held_since + HOLD_CEILING` beside
    /// an inner deadline armed by the second change. Tightening is monotonic: a third
    /// change and every one after it names a later instant than the second's, so taking
    /// the minimum each time leaves the second change's answer standing, which is exactly
    /// what the two-field version spelled with a `get_or_insert`.
    ceiling_at: Option<std::time::Instant>,
    /// When the window a keystroke opened for its echo closes; see [`ECHO_WINDOW`].
    ///
    /// Taken by the first drawable read on a shown screen, whether or not it has expired,
    /// so one keystroke can turn into at most one waived frame however much the child
    /// writes after it. `None` while no keystroke is waiting.
    echo_until: Option<std::time::Instant>,
    /// Whether the frame being assembled carries a keystroke's echo, which lets it skip
    /// `min_interval`; the other three gates in [`Notifier::flush`] still apply.
    ///
    /// Only the throttle is waived because it is the only gate that is a pure clock.
    /// [`QUIESCENCE`] is what keeps a line editor redrawing its line in several writes
    /// from being drawn half done, and echo is exactly that write, so the echo still waits
    /// for the pty to go quiet. A child that never goes quiet is still drawn at
    /// `frame_ceiling`, which this leaves alone: waiving it would hold the frame for
    /// [`HOLD_CEILING`] instead.
    ///
    /// Set by [`Notifier::fed`] from `echo_until`, and cleared by the flush that sends the
    /// frame, so under a flood with a key held down the wake rate rises by at most one
    /// frame per keystroke.
    echo: bool,
}

/// What is keeping the frame being assembled off the screen; see [`NotifyState::decide`].
enum Hold {
    /// Nothing is, so it may be sent now.
    Ready,
    /// It is held until this instant, the *last* of the gates that still hold it.
    ///
    /// The last rather than the first because a frame one gate has released is not
    /// released, so a reader woken at the earliest deadline would find the rest still
    /// holding and go straight back to sleep -- the spin [`Notifier::poll_wait`] used to
    /// guard against by taking a `max` of its own.
    Until(std::time::Instant),
}

impl NotifyState {
    /// What is holding this frame at NOW, and until when.
    ///
    /// The one reading of the four gates: the client's own sync marker, the redisplay
    /// throttle, and the quiescence wait with the ceilings that bound it.
    /// [`Notifier::flush`] sends on [`Hold::Ready`] and [`Notifier::poll_wait`] sleeps
    /// until the instant [`Hold::Until`] names, so the two cannot come to different
    /// conclusions about the same state. Nothing else reads the deadlines.
    ///
    /// A deadline standing exactly at NOW counts as still holding, for all four alike. The
    /// wait it names is then zero, so nothing rides on which way that falls, and one rule
    /// for the four gates is worth more than reproducing each gate's old boundary.
    fn decide(&self, now: std::time::Instant) -> Hold {
        let gates = [
            // The client's own marker, DEC mode 2026; see [`Notifier::set_sync`].
            self.sync_until,
            // The redisplay floor, which a keystroke's echo waives; see [`Self::echo`].
            self.last
                .filter(|_| !self.echo)
                .map(|t| t + self.min_interval),
            self.quiescent_until(now),
        ];
        match gates.into_iter().flatten().filter(|at| *at >= now).max() {
            Some(at) => Hold::Until(at),
            None => Hold::Ready,
        }
    }

    /// When this frame stops being held back for the child to finish writing it, or `None`
    /// if it is not being held back at all.
    ///
    /// The quiescence rule. It has the same shape as DEC mode 2026 -- hold the frame, keep
    /// `dirty` set, retire at a deadline -- with the pty going quiet standing in for the
    /// child's cooperation, so it works for clients that never send a 2026 sequence.
    ///
    /// Two deadlines, whichever comes first: [`QUIESCENCE`] since the last byte arrived,
    /// and the frame's own [`Self::ceiling_at`]. `last_read` unset — which
    /// [`Notifier::announce`] arranges — means there is nothing to wait for at all.
    fn quiescent_until(&self, now: std::time::Instant) -> Option<std::time::Instant> {
        let mut at = self
            .last_read
            .map(|t| t + self.quiescence)
            .filter(|at| *at >= now)?;
        // A ceiling that has *passed* releases the frame outright, so it is asked
        // separately rather than folded into the `min` with a default that would read as
        // "no deadline".
        if let Some(ceiling) = self.ceiling_at {
            if ceiling < now {
                return None;
            }
            at = at.min(ceiling);
        }
        Some(at)
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
                quiescence: options.quiescence,
                last: None,
                sync_until: None,
                last_read: None,
                ceiling_at: None,
                echo_until: None,
                echo: false,
            }),
            clock: options.clock.clone(),
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
        drop(state);
        self.flush()
    }

    /// A keystroke is about to be written, so the frame that echoes it may skip
    /// `min_interval`; see [`NotifyState::echo`].
    ///
    /// Called before the write rather than after it, because the child's echo can reach
    /// the reader thread before the writing thread gets the lock back.
    fn expect_echo(&self) {
        self.state.held().echo_until = Some(self.clock.now() + ECHO_WINDOW);
    }

    /// Note a read from the pty, `drawable` saying whether it changed anything Emacs
    /// would draw, and `shown` whether any window shows the screen it changed.
    ///
    /// The entry point for output, in place of [`Self::announce`]: it marks the frame and
    /// leaves the decision of when to draw it to [`Self::flush`], which the reader
    /// retries on every tick. Both halves of [`NotifyState::quiescent_until`] are armed
    /// here — the timestamp on every read, and the frame's ceiling, in the two stages
    /// [`NotifyState::ceiling_at`] describes; `dirty` already being set is what says this
    /// is not the frame's first change.
    ///
    /// A keystroke's echo window is taken here too. A hidden screen leaves it alone: the
    /// drawable read there is a bell or a prompt mark, which Emacs handles without drawing
    /// anything, so there is no echo on screen to hurry, and a hidden buffer woken early
    /// would pay a drain for nothing.
    fn fed(&self, drawable: bool, shown: bool) {
        let now = self.clock.now();
        let mut state = self.state.held();
        state.last_read = Some(now);
        if drawable && shown && remaining(state.echo_until.take(), now).is_some() {
            state.echo = true;
        }
        if drawable {
            if self.dirty.swap(true, Ordering::SeqCst) {
                // A second change, or a later one: bring the deadline in to the pace a busy
                // client is drawn at, never push it out. `None` here is a frame whose
                // deadlines [`Self::announce`] cleared without the flush behind it getting
                // out, which starts the ceiling afresh rather than leaving it unbounded.
                let at = now + state.frame_ceiling;
                state.ceiling_at = Some(state.ceiling_at.map_or(at, |held| held.min(at)));
            } else {
                // The first change of a frame, which one change is not yet evidence of more
                // to come: only the outer bound is armed.
                state.ceiling_at = Some(now + HOLD_CEILING);
            }
        }
    }

    /// Send the wake byte if something is pending, nothing is already in flight, and
    /// `min_interval` has elapsed since the last send or the frame carries a keystroke's
    /// echo.
    fn flush(&self) -> bool {
        if self.notified.load(Ordering::SeqCst) || !self.dirty.load(Ordering::SeqCst) {
            return true;
        }
        let now = self.clock.now();
        let mut state = self.state.held();
        // Asked before `dirty` is cleared, deliberately: leaving it set is what hands a
        // held frame to the retry machinery, so it is drawn the moment the last gate opens
        // rather than waiting on the child's next write.
        if matches!(state.decide(now), Hold::Until(_)) {
            return true;
        }
        state.last = Some(now);
        state.ceiling_at = None;
        state.echo = false;
        drop(state);
        self.dirty.store(false, Ordering::SeqCst);
        self.notify()
    }

    /// Emacs has taken the delta, so the wake byte we sent has done its work.
    ///
    /// This says nothing about when the next byte may go out; [`Self::rearm`] does, and
    /// Lisp calls it once the delta is applied to the buffer. The two sit at opposite ends
    /// of Emacs' work because taking a delta is cheap and applying it is most of the cost
    /// of a frame -- about 12ms for a screen of box drawing. Re-arming here would end the
    /// backpressure window before the apply, and `min_interval` would always have elapsed
    /// by the time it was consulted.
    fn acknowledge(&self) {
        self.notified.store(false, Ordering::SeqCst);
    }

    /// Emacs has applied the delta, so the next change is worth another byte.
    ///
    /// Returns whether a throttled notification is still waiting. Flushing here retires
    /// the ordinary case, where the apply ends after `min_interval` has already elapsed.
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
    /// `base` is the caller's answer for the quiet case, [`Shared::base_poll_wait`]'s
    /// backoff. It is a parameter because how often the tty is worth
    /// asking about is a termios question, which the notifier has no business knowing.
    /// What the notifier owns are the deadlines below, which override the base.
    ///
    /// Real pty data wakes `poll` at once, so the base is coarse. But when a frame is
    /// held -- by the throttle, by the client's marker, or by the quiescence rule -- and
    /// the child then falls quiet, nothing else wakes the loop, and waiting out
    /// `POLL_TIMEOUT_MS` would add up to 100ms to the last frame of a burst, felt as a
    /// stutter at the end of a wheel scroll in a full-screen program. Sleeping to the
    /// instant [`NotifyState::decide`] names avoids that and retires each hold on time.
    fn poll_wait(&self, base: std::time::Duration) -> std::time::Duration {
        if self.notified.load(Ordering::SeqCst) || !self.dirty.load(Ordering::SeqCst) {
            return base;
        }
        let now = self.clock.now();
        match self.state.held().decide(now) {
            Hold::Until(at) => at.saturating_duration_since(now),
            // Nothing holds it, so the next [`Self::flush`] sends it and there is nothing
            // to wait for here.
            Hold::Ready => std::time::Duration::ZERO,
        }
    }

    /// Close the wake pipe, so Emacs' read end sees EOF.
    fn close(&self) {
        drop(self.wake.held().take());
    }
}

/// How much of a deadline is left at NOW, or `None` if it has passed or was never set.
///
/// NOW is a parameter rather than read here so that every deadline a decision weighs is
/// weighed against the same instant, and so that [`Clock`] reaches this too.
fn remaining(
    deadline: Option<std::time::Instant>,
    now: std::time::Instant,
) -> Option<std::time::Duration> {
    deadline.and_then(|t| t.checked_duration_since(now))
}

struct Shared {
    pty: Pty,
    term: Mutex<Term>,
    /// How many threads other than the reader are blocked on `term`, or about to be; see
    /// [`Shared::term_for_lisp`] and [`Shared::feed`].
    ///
    /// The reader reads this between the slices of a parse and steps out of the way when
    /// it is not zero, so that a drain waits on eight kilobytes of parsing rather than on
    /// sixty-four.
    ///
    /// A count rather than the flag this could be, because two waiters clearing one flag
    /// would have the first to arrive cancel the second's claim, and the cost of the
    /// difference is nothing: both are one atomic on a path that is about to block on a
    /// mutex anyway. Emacs' module calls do come from one thread, but `Session::drop`
    /// reaches this from whichever thread ran the garbage collector, and the compile pump
    /// drains sessions of its own.
    lisp_waiters: AtomicUsize,
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
    /// How many threads are inside a write to the child that may block; see
    /// [`Sending`] and the throttle in [`Shared::read_loop`].
    ///
    /// A count rather than a flag because [`Session::send`] is not the only caller Lisp
    /// can reach: the writer mutex serialises the writes themselves, but a second sender
    /// waiting for it must not let the first one's exemption lapse.
    sending: AtomicUsize,
    mode: AtomicMode,
    /// A size the child is not yet known to have, for the reader thread to keep applying
    /// until it sticks. `None` once the tty agrees. See `Session::resize`.
    pending_resize: Mutex<Option<Winsize>>,
    /// Everything to do with telling Emacs there is something to draw; see [`Notifier`].
    notifier: Notifier,
    /// Where the deadlines below are read against; see [`Clock`]. The same clock the
    /// notifier holds, so the two never disagree about when a tick is due.
    clock: Clock,
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
    /// How many ticks in a row have found nothing, for the backoff in
    /// [`Shared::base_poll_wait`]. Zeroed by [`Shared::activity`].
    quiet_ticks: AtomicU32,
    /// Whether the reader has stopped pulling from the pty because the backlog is full;
    /// see [`Shared::read_loop`]. A drain is what empties the backlog, so a drain that
    /// finds this set wakes the reader through the interrupt rather than leaving it to
    /// the poll tick.
    throttled: AtomicBool,
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
    /// Make the next read from the pty panic, to stand in for a defect in the parser or
    /// a decoder; see [`Shared::run_reader`]. Compiled out of a release build.
    #[cfg(test)]
    panic_on_read: AtomicBool,
}

/// A claim on [`Shared::lisp_waiters`], held from just before a thread blocks on the
/// terminal lock until just after it has it.
///
/// An RAII guard rather than a pair of calls because the release has to happen on the
/// panicking path too: the emulator's mutex is taken through [`LockExt::held`] precisely
/// so that a panic which unwound out of it does not freeze the buffer, and a claim leaked
/// by that same panic would leave the reader yielding on every slice for the life of the
/// session.
///
/// Dropped once the lock is *taken*, not once it is released: what the reader is being
/// asked is "is somebody waiting", and a thread that has the lock is no longer waiting
/// for it.
struct Waiting<'a>(&'a AtomicUsize);

impl<'a> Waiting<'a> {
    fn on(waiters: &'a AtomicUsize) -> Self {
        waiters.fetch_add(1, Ordering::SeqCst);
        Self(waiters)
    }
}

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// A write to the child in progress on Emacs' thread, which suspends the backlog
/// throttle for as long as it lasts; see [`Shared::sending`].
///
/// The throttle exists to make a child that outruns Emacs block in its own `write`
/// rather than pile up in memory, and it does that by leaving the pty unread. That is
/// exactly wrong while Emacs is blocked in a write of its own: a paste of more lines
/// than `backlog_limit` is echoed back, the reader stops reading, the child's output
/// queue fills, the child stops reading, and both sides wait out `WRITE_TIMEOUT` before
/// the paste fails. What the throttle would be protecting here is memory bounded by the
/// paste itself, which Emacs already holds in full, so reading on costs nothing it was
/// meant to save.
///
/// A guard rather than a pair of stores, because a write that fails -- a timeout, a
/// `C-g`, an unwinding panic -- must not leave the throttle suspended for the life of
/// the session.
struct Sending<'a>(&'a Shared);

impl<'a> Sending<'a> {
    fn on(shared: &'a Shared) -> Self {
        shared.sending.fetch_add(1, Ordering::SeqCst);
        // The reader is asleep in a `poll` that watches nothing but the interrupt while
        // it is throttled, so without this it would not look at the count until its next
        // tick -- and would then have to look again after every one.
        shared.unthrottle();
        Self(shared)
    }
}

impl Drop for Sending<'_> {
    fn drop(&mut self) {
        self.0.sending.fetch_sub(1, Ordering::SeqCst);
    }
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
#[derive(Debug, Clone)]
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
    /// Where the pacing reads the time; see [`Clock`].
    ///
    /// Carried here rather than taken by [`Session::spawn`] so that the Lisp side is
    /// unchanged by its existence: nothing but a test ever sets it.
    pub clock: Clock,
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
            clock: Clock::default(),
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
            lisp_waiters: AtomicUsize::new(0),
            replies: Mutex::new(ReplyQueue::default()),
            writer: Mutex::new(()),
            sending: AtomicUsize::new(0),
            mode: AtomicMode::new(mode),
            pending_resize: Mutex::new(None),
            clock: options.clock.clone(),
            notifier: Notifier::new(wake, &options),
            resample_at: Mutex::new(None),
            backlog_limit: AtomicUsize::new(options.backlog_limit),
            quiet_ticks: AtomicU32::new(0),
            throttled: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
            attended: AtomicBool::new(true),
            hidden: AtomicBool::new(false),
            interacted_until: Mutex::new(None),
            interrupt: Interrupt::new()?,
            exited: Mutex::new(None),
            #[cfg(test)]
            panic_on_read: AtomicBool::new(false),
        });

        let reader = std::thread::Builder::new()
            .name("cooked-reader".into())
            .spawn({
                let shared = Arc::clone(&shared);
                move || shared.run_reader()
            })?;

        Ok(Self {
            shared,
            reader: Mutex::new(Some(reader)),
        })
    }

    /// Tear the child down now and reap it, reporting whether this call was the one that
    /// did it. Idempotent, cheap after the first call, and safe from `Drop`.
    ///
    /// What a terminal window closing does: the shell is hung up, given
    /// [`HANGUP_GRACE`] to forward that to its jobs and save its history, and only then
    /// killed. Emacs must never wait on someone else's `sleep 3600`, and a child that
    /// ignores SIGHUP -- `nohup`, `trap '' HUP` -- would otherwise survive an explicit
    /// kill and never be reaped, which is what the SIGKILL is for.
    ///
    /// The grace is a bound and not a cost: the reader reaps the child the moment its
    /// side of the pty closes, so a shell that exits at once is reaped at once.
    ///
    /// The wait is paid here, on the caller's thread, and that is deliberate for the
    /// explicit kill: `cooked--kill-emacs' runs this from `kill-emacs-hook', where the
    /// reader has no future to finish anything in, so a child that ignores SIGHUP has to
    /// be killed before this returns or it outlives the Emacs that started it. [`Drop`]
    /// is the path that cannot afford the wait; see [`Session::drop`].
    pub(crate) fn shutdown(&self) -> bool {
        if !self.begin_shutdown() {
            return false;
        }
        self.shared.reap_after_hangup();
        true
    }

    /// The half of teardown that costs nothing: stop the reader, hang up on the child,
    /// and stop talking to Emacs. Reports whether this call was the first.
    ///
    /// Both paths out of a session start here. What they differ on is who waits out the
    /// grace afterwards.
    fn begin_shutdown(&self) -> bool {
        if self.shared.shutdown.swap(true, Ordering::SeqCst) {
            return false;
        }
        let _ = self.shared.pty.hangup();
        self.shared.interrupt.raise();
        self.shared.notifier.close();
        // Detached rather than joined. A reader inside `job.run()` decoding a picture holds
        // no lock and checks no flag, so joining it parked *this* thread -- the one holding
        // the `emacs_env`, which `Drop` reaches from the garbage collector -- for the length
        // of a decode bounded only by `sixel::MAX_PIXELS` and the kitty caps. It observes
        // `shutdown` on its next turn instead and leaves without reading the pty again.
        drop(self.reader.held().take());
        true
    }

    /// The emulator, locked, for a caller that only needs to ask it something or tell it
    /// something.
    ///
    /// The methods on `Session` itself are the ones with policy of their own -- a resize
    /// that also sets the tty, a send that counts as interaction -- so a plain question
    /// about the grid goes straight to [`Term`] rather than through a one-line forwarder
    /// here.
    ///
    /// Through [`Shared::term_for_lisp`], as every path here that reaches the emulator
    /// from Emacs' thread is, so the reader steps out of the way mid-parse rather than
    /// making this wait out a whole read.
    pub(crate) fn term(&self) -> MutexGuard<'_, Term> {
        self.shared.term_for_lisp()
    }
}

impl Shared {
    /// Wait out the grace [`Session::begin_shutdown`]'s hangup bought, kill a child that
    /// ignored it, and record what it exited with.
    ///
    /// Whichever thread gets here first does the work, and the other finds the status
    /// already written and returns at once. Idempotent, and after the first call it is
    /// three atomic reads: [`Pty::reap`] answers `None` immediately once the child has
    /// been collected, and [`Pty::kill`] refuses to signal a reaped pid.
    fn reap_after_hangup(&self) {
        let mut exited = self.exited.held();
        if exited.is_none() {
            // Held across the reap, so the reader cannot record a status in the middle of
            // it. The two can still race for the `waitpid` itself -- a reader already past
            // its own `shutdown` check is the window -- and `reap_lock` lets exactly one of
            // them collect it. Losing that race is not losing the status: `Pty::collected`
            // is where the winner left it, and reading it here rather than waiting for the
            // reader to record it is what keeps `alive` answering no the moment this
            // returns. `LOST` is left for a child nobody reaped at all.
            *exited = Some(
                self.reap_or_kill()
                    .or_else(|| self.pty.collected())
                    .unwrap_or(LOST),
            );
        }
    }
}

impl Session {
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
    /// which Emacs calls once it has applied what this returned. See
    /// [`Notifier::acknowledge`] for why the window covers the render rather than the
    /// collection.
    ///
    /// [`Delta::promoted`]: crate::emu::Delta::promoted
    pub(crate) fn drain_with(&self, promote: bool) -> Update {
        self.shared.notifier.acknowledge();
        let mut term = self.shared.term_for_lisp();
        let delta = if promote {
            term.drain_promoting()
        } else {
            term.drain()
        };
        drop(term);
        self.shared.unthrottle();
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
        let mut term = self.shared.term_for_lisp();
        let delta = if exit.is_some() {
            term.drain()
        } else {
            term.drain_hidden()
        };
        drop(term);
        self.shared.unthrottle();
        Update {
            delta,
            mode: self.shared.mode.load(),
            exit,
        }
    }

    /// Emacs has applied the last drain to its buffer and will take another wakeup.
    ///
    /// One wake byte is in flight until this is called, so the child's writes accumulate
    /// in [`Term`] rather than each buying a buffer update. Calling it here, after the
    /// apply, makes `min_redisplay_interval` a floor on how often Lisp applies a drain,
    /// which is where most of the cost is.
    ///
    /// It is not a report that the frame is on screen. `cooked--drain-and-apply` calls it
    /// from inside the process filter, and Emacs redisplays after the filter returns, so
    /// the window ends before the redraw it pays for. Emacs does redraw between wakes in
    /// practice, 91 redisplays against 40 applies with `yes` flooding a buffer, but it is
    /// the interval that leaves it the room, not this call.
    ///
    /// Safe to omit, as the tests and the benchmark do: a session nobody re-arms is woken
    /// by the reader's ordinary tick instead, slower but never stuck.
    /// `cooked--drain-and-apply` still calls it from an `unwind-protect` cleanup.
    pub(crate) fn ready(&self) {
        // The drain's events are handled, so Lisp has queued every answer it owed, and the
        // replies that waited behind them may follow.
        let outbound = {
            let mut term = self.shared.term_for_lisp();
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
    /// paste into a stopped job always has -- or sooner, with [`Error::Interrupted`](crate::error::Error::Interrupted),
    /// when STOP says so; `cooked--send` passes `should_quit`, so `C-g` ends the wait.
    /// Replies already queued go first, inside the same deadline: they were owed before
    /// this input was typed, and writing input between the halves of a reply would
    /// garble both.
    ///
    /// INPUT says whether a key was pressed. [`Input::Keyboard`] lets the frame that
    /// echoes it skip `min_interval`; see [`ECHO_WINDOW`]. The window opens before
    /// [`Shared::interacted`], whose early return for an attended session would otherwise
    /// be an easy place to lose it.
    pub(crate) fn send(&self, bytes: &[u8], input: Input, stop: &dyn Fn() -> bool) -> Result<()> {
        if input == Input::Keyboard {
            self.shared.notifier.expect_echo();
        }
        self.shared.interacted();
        let wait = Wait::new(std::time::Instant::now() + WRITE_TIMEOUT, stop);
        // Taken before the writer mutex, so a second sender waiting for that one does not
        // let the first sender's exemption lapse; see [`Sending`].
        let _sending = Sending::on(&self.shared);
        let writer = self.shared.writer.held();
        let result = self.shared.write_after_replies(bytes, &wait);
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
                .term_for_lisp()
                .set_size(size.rows.into(), size.cols.into(), size.cell);
        *self.shared.pending_resize.held() = Some(size);
        // Wake the reader rather than leaving the retry to its next tick, which under
        // [`UNATTENDED_TICK_CAP`] can be seconds away for a buffer resized while off
        // screen. Resizes are rare, so the extra wakeup costs nothing.
        self.shared.activity();
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
    /// Attended, the tick backs off to [`ATTENDED_TICK_CAP`]; unattended, to
    /// [`UNATTENDED_TICK_CAP`], four times longer, because the tick only notices silent
    /// termios changes and there is nobody to tell. Emacs decides what "looking" means,
    /// from `cooked--attention`.
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
            self.shared.activity();
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
    /// Normally a no-op: `cooked--kill` runs from `kill-buffer-hook`, so by the time the
    /// garbage collector finalises the handle there is nothing left to do. This is the
    /// backstop for a session nobody killed explicitly.
    ///
    /// It hangs up and returns, rather than calling [`Session::shutdown`] and waiting.
    /// This runs inside Emacs' garbage collector, and a child that ignores SIGHUP --
    /// `nohup`, `trap '' HUP` -- would hold the whole editor still for
    /// [`HANGUP_GRACE`] plus [`KILL_GRACE`], half a second, at a moment nothing in Lisp
    /// asked for. The grace, the kill and the reap are left to the reader thread, which
    /// outlives this handle -- it holds an `Arc` of its own -- and which
    /// [`Shared::read_loop`] sends through [`Shared::reap_after_hangup`] on its way out.
    ///
    /// Nobody is left to hear the status, which is why it need not be waited for: the
    /// notifier is closed, the handle is being finalised, and a `Session` Lisp can no
    /// longer reach is one nothing will ask `alive` or drain again.
    fn drop(&mut self) {
        self.begin_shutdown();
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
    /// How long the next poll may sleep, and whether that is the quiet tick itself
    /// rather than a nearer deadline -- a held frame, a throttled notification, a
    /// resample -- that happens to be shorter. Only the tick counts as quiet when it
    /// expires; see [`Shared::quiet_tick`].
    ///
    /// A `Duration` rather than a `PollTimeout`, because the deadlines here are shorter
    /// than the millisecond `poll` counts in: [`QUIESCENCE`] is half of one, and the tail
    /// of a redisplay interval is whatever is left of it. Narrowed to milliseconds those
    /// truncated to zero, and a zero timeout is not a wait but a spin -- the reader went
    /// round its whole iteration, `tcgetattr` and the terminal lock included, as fast as
    /// it could until the deadline passed. `platform::poll` waits to the precision the
    /// platform has.
    fn poll_timeout(&self) -> (std::time::Duration, bool) {
        let tick = self.base_poll_wait();
        let mut wait = self.notifier.poll_wait(tick);
        if let Some(left) = remaining(*self.resample_at.held(), self.clock.now()) {
            wait = wait.min(left);
        }
        (wait, wait >= tick)
    }

    /// How long a quiet tick lasts: [`POLL_TIMEOUT_MS`] doubled for every tick that has
    /// found nothing since the last activity, up to a cap attention decides.
    ///
    /// Two things earn the shorter cap: attention, which is Emacs saying the buffer is
    /// under the user's eyes, and [`INTERACTION_WINDOW`], which covers a terminal being
    /// scrolled in an unselected window. See [`ATTENDED_TICK_CAP`] for the backoff.
    ///
    /// Pinned at the base while a resize has not taken or a reply waits for room: both
    /// ride on the tick and neither is a thing to let a quiet session decay.
    fn base_poll_wait(&self) -> std::time::Duration {
        let base = std::time::Duration::from_millis(u64::from(POLL_TIMEOUT_MS));
        if self.pending_resize.held().is_some() || self.awaits_room() {
            return base;
        }
        let cap = if self.attended.load(Ordering::Relaxed) || self.interacting() {
            ATTENDED_TICK_CAP
        } else {
            UNATTENDED_TICK_CAP
        };
        let doublings = self
            .quiet_ticks
            .load(Ordering::Relaxed)
            .min(TICK_DOUBLINGS_MAX);
        (base * (1 << doublings)).min(cap)
    }

    /// Something happened -- output, input, a resize, attention -- so the next quiet tick
    /// starts short again; see [`Shared::base_poll_wait`].
    fn activity(&self) {
        self.quiet_ticks.store(0, Ordering::Relaxed);
    }

    /// A tick found nothing: the next one may wait longer.
    fn quiet_tick(&self) {
        let _ = self
            .quiet_ticks
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
                (n < TICK_DOUBLINGS_MAX).then_some(n + 1)
            });
    }

    /// Whether input has been sent recently enough to owe this session the eager tick.
    fn interacting(&self) -> bool {
        remaining(*self.interacted_until.held(), self.clock.now()).is_some()
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
        self.activity();
        if self.attended.load(Ordering::Relaxed) {
            return;
        }
        let mut until = self.interacted_until.held();
        let now = self.clock.now();
        let was_interacting = remaining(*until, now).is_some();
        *until = Some(now + INTERACTION_WINDOW);
        drop(until);
        if !was_interacting {
            self.interrupt.raise();
        }
    }

    /// Ask again shortly, because the child just wrote something; see [`RESAMPLE_DELAY`].
    fn arm_resample(&self) {
        *self.resample_at.held() = Some(self.clock.now() + RESAMPLE_DELAY);
    }

    /// Retire an armed resample once its moment has come and gone.
    ///
    /// The sample itself is [`Shared::sample_mode`]'s, taken unconditionally on every tick
    /// -- this only decides *when* the tick happens, so once the deadline is behind us
    /// there is nothing left for it to bring forward.
    fn retire_resample(&self) {
        let mut at = self.resample_at.held();
        if at.is_some_and(|t| t <= self.clock.now()) {
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

    /// A drain has emptied the backlog: wake a reader that stopped on it.
    ///
    /// The wake is the interrupt, and it is sent only when the reader said it had
    /// stopped, so an ordinary drain costs no syscall here. The reader re-reads the
    /// backlog for itself on waking, so a drain that left it still full is harmless.
    fn unthrottle(&self) {
        if self.throttled.load(Ordering::SeqCst) {
            self.interrupt.raise();
        }
    }

    /// Whether the reader should watch the pty for room: replies are waiting, and no
    /// sender is about to write them itself.
    fn awaits_room(&self) -> bool {
        !self.replies.held().is_empty()
            && !matches!(self.writer.try_lock(), Err(TryLockError::WouldBlock))
    }

    /// [`Session::send`]'s write, after the replies queued ahead of it.
    fn write_after_replies(&self, bytes: &[u8], wait: &Wait<'_>) -> Result<()> {
        loop {
            let mut queue = self.replies.held();
            queue.flush(|b| self.pty.write_some(b))?;
            if queue.is_empty() {
                break;
            }
            drop(queue);
            self.pty.wait_writable(wait)?;
        }
        self.pty.write(bytes, wait)
    }

    /// The reader thread's body: [`Shared::read_loop`], with a panic in it ending the
    /// session rather than the thread alone.
    ///
    /// `env::trampoline` catches a panic on Emacs' thread and turns it into a Lisp
    /// signal, and nothing did the same here. A panic in the parser or a picture decoder
    /// -- on bytes the child chose -- unwound this thread and left everything else as
    /// it was: `exited` unset, so `alive` went on answering yes; no wake byte, so Emacs
    /// was never told; a child still running against a pty nobody would read again.
    /// The buffer froze, silently, for good.
    ///
    /// So the panic is caught and treated as the abort it is: the child is hung up and
    /// reaped and Emacs is woken, exactly as for a `poll` that failed. Poisoned locks are
    /// no obstacle, since every lock in the crate is taken through [`LockExt::held`].
    /// What was being parsed is lost, which is the least of it.
    fn run_reader(&self) {
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.read_loop()));
        if outcome.is_err() && !self.shutdown.load(Ordering::SeqCst) {
            self.finish(Ended::Aborted);
        }
    }

    fn read_loop(&self) {
        block_sigpipe();
        let mut buf = vec![0u8; READ_CHUNK];

        while !self.shutdown.load(Ordering::SeqCst) {
            // Backpressure: with a full backlog, leave the bytes in the pty. Its buffer
            // fills and the child blocks in `write`, so output waits instead of being
            // dropped or piling up in memory faster than Emacs can render it. The pty is
            // then not polled for input at all -- a readable pty nobody reads would
            // return from every poll at once -- and the drain that empties the backlog
            // raises the interrupt to say so; see [`Shared::unthrottle`].
            let full = {
                let mut term = self.term.held();
                // Once a tick, while the lock is held anyway: see `Term::sweep`.
                term.sweep();
                term.backlog() >= self.backlog_limit.load(Ordering::Relaxed)
            };
            // Not while a send is blocked on the child, which the throttle would
            // otherwise deadlock against its own echo; see [`Sending`].
            let throttled = full && self.sending.load(Ordering::SeqCst) == 0;
            self.throttled.store(throttled, Ordering::SeqCst);
            if throttled {
                // A child that filled the backlog inside one frame has forfeited atomicity:
                // holding the wakeup here would deadlock the backlog against its own blocked
                // write, waiting on a frame it cannot finish because we are not reading.
                self.notifier.set_sync(None);
                self.announce();
            }
            // Room is watched for only while a reply waits for it: a child that is not
            // reading keeps the pty full, and a writable pty with nothing to write would
            // return from every poll at once.
            let mut events = if throttled {
                PollFlags::empty()
            } else {
                PollFlags::POLLIN
            };
            if self.awaits_room() {
                events |= PollFlags::POLLOUT;
            }
            let mut fds = [
                PollFd::new(self.pty.as_fd(), events),
                PollFd::new(self.interrupt.read.as_fd(), PollFlags::POLLIN),
            ];
            let (wait, is_tick) = self.poll_timeout();
            match crate::platform::poll(&mut fds, wait) {
                Err(nix::errno::Errno::EINTR) => continue,
                Err(_) => break,
                Ok(_) => {}
            }
            let interrupted = fds[1].revents().is_some_and(|r| !r.is_empty());
            let revents = fds[0].revents().unwrap_or(PollFlags::empty());
            let ready = !(revents - PollFlags::POLLOUT).is_empty();
            // A tick that ran out with nothing to show for it lets the next one wait
            // longer. A poll the interrupt woke, or one cut short by a nearer deadline,
            // is neither quiet nor activity.
            if !ready && !interrupted && is_tick {
                self.quiet_tick();
            }
            // Either teardown asked us to stop -- in which case read no further, and finish
            // the teardown below -- or a drain left a throttled notification for the
            // `flush` below, and all that was wanted was this iteration itself.
            if interrupted {
                self.interrupt.clear();
                if self.shutdown.load(Ordering::SeqCst) {
                    break;
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
            // [`NotifyState::quiescent_until`] waits for. The rule lives in `flush` so that `rearm`
            // on Emacs' thread obeys it too.
            self.flush();

            // A hangup or error still arrives while throttled, since those need no
            // event bits asked for, and the read below is what reports them.
            if !ready || (throttled && !revents.intersects(PollFlags::POLLHUP | PollFlags::POLLERR))
            {
                continue;
            }

            match self.pty.read(&mut buf) {
                Ok([]) => return self.finish_at_hangup(),
                Ok(data) => {
                    #[cfg(test)]
                    if self.panic_on_read.swap(false, Ordering::SeqCst) {
                        panic!("a defect in the parser, as the test asked for");
                    }
                    self.activity();
                    let hidden = self.hidden.load(Ordering::Relaxed);
                    let (drawable, outbound) = self.feed(data, hidden);
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
                    self.notifier.fed(drawable, !hidden);
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
                    return self.finish_at_hangup();
                }
                // The master is non-blocking, and a poll that reported a hangup or an error
                // can find nothing to read after all.
                Err(e) if e.is(Errno::EINTR) || e.is(Errno::EAGAIN) => {}
                Err(_) => return self.finish(Ended::Aborted),
            }
        }

        // Either teardown set `shutdown`, in which case the grace the hangup bought is
        // this thread's to wait out -- `Session::drop` hands it over rather than hold
        // Emacs' garbage collector still for it, and an explicit `Session::shutdown` has
        // already done the same work, so this costs nothing after it -- or the poll
        // failed and this session has to end itself.
        if self.shutdown.load(Ordering::SeqCst) {
            self.reap_after_hangup();
        } else {
            self.finish(Ended::Aborted);
        }
    }

    /// The child's exit status, after the hangup it has been sent and, failing that, a
    /// kill. `None` only for a child that cannot be reaped even then.
    fn reap_or_kill(&self) -> Option<i32> {
        self.pty.reap(HANGUP_GRACE).or_else(|| {
            let _ = self.pty.kill();
            self.pty.reap(KILL_GRACE)
        })
    }

    /// The end of the reader for a pty that hung up, with the wait for a child that has
    /// not exited yet included.
    ///
    /// Teardown is the one thing that cuts that wait short, and it leaves this thread
    /// holding the obligation the ordinary end of [`Shared::read_loop`] holds: the grace
    /// the hangup bought is the reader's to wait out, because [`Session::drop`] hands it
    /// over rather than hold Emacs' garbage collector still for it.
    fn finish_at_hangup(&self) {
        self.finish(Ended::ChildGone);
        if self.shutdown.load(Ordering::SeqCst) {
            self.reap_after_hangup();
        }
    }

    /// Wait for a child that hung the pty up without exiting, so that the status it does
    /// exit with is still the one reported.
    ///
    /// Reached only from [`Shared::finish`], once the first [`REAP_PATIENCE`] has gone by
    /// with nothing to collect. The case is a direct child that let go of its tty and
    /// kept running -- `exec 0<&- 1>&- 2>&-; sleep 30` in the shell we started, or
    /// anything else that daemonises itself the classical way: the last descriptor on the
    /// slave is gone, so the master reports EIO at once, while the child is still running
    /// and still ours to reap. (A background job holding the slave open is the opposite
    /// case and does not come here: the master never hangs up at all.)
    ///
    /// Waiting rather than escalating to the hangup and kill `Ended::Aborted` sends. A
    /// child that closed its tty on purpose has not asked to be killed, and no terminal
    /// kills one for it. Walking away instead -- which is what recording nothing amounted
    /// to -- is worse than either: the child is ours, so nobody else will ever reap it,
    /// and it would sit in Emacs as a zombie for as long as Emacs runs, with `alive`
    /// answering yes about it the whole time.
    ///
    /// The cost of waiting is one thread parked in `poll` on the exit watch -- a pidfd on
    /// Linux, a kqueue on macOS -- which is the reader, and it has nothing else left to
    /// do. It is woken the moment the child exits, and otherwise once every
    /// [`REAP_PATIENCE`], which is what bounds how long teardown takes to be noticed.
    ///
    /// `None` only for a wait teardown stopped, and then the child is
    /// [`Shared::reap_after_hangup`]'s, which is where the grace, the kill and [`LOST`]
    /// are.
    fn linger_for_exit(&self) -> Option<i32> {
        while !self.shutdown.load(Ordering::SeqCst) {
            if let Some(status) = self.pty.reap(REAP_PATIENCE) {
                return Some(status);
            }
            // `Pty::reap` answers `None` three ways and only one of them, the timeout, is
            // worth another turn. A child somebody else collected -- an explicit
            // `Session::shutdown` on Emacs' thread, racing this -- left its status in
            // `Pty::collected` for us to read.
            if let Some(status) = self.pty.collected() {
                return Some(status);
            }
            match self.pty.try_wait() {
                Ok(None) => {}
                Ok(Some(status)) => return Some(status),
                // A `waitpid` that refuses the pid outright -- `ECHILD` for a child that
                // is not ours any more -- will refuse it just as flatly in another half
                // second, and there is no status left to be had.
                Err(_) => return Some(LOST),
            }
        }
        None
    }

    fn finish(&self, why: Ended) {
        let status = match why {
            // A child can hang the pty up without being reapable yet, and even without
            // exiting at all; see [`Shared::linger_for_exit`].
            Ended::ChildGone => self
                .pty
                .reap(REAP_PATIENCE)
                .or_else(|| self.linger_for_exit()),
            // The reader is leaving with the child still there. Nothing will read the pty
            // again, so the session is over whether or not the child agrees, and a
            // session that ends has to say so: left as it was, `alive` went on
            // answering yes for a buffer nothing would ever write to again.
            Ended::Aborted => {
                let _ = self.pty.hangup();
                self.reap_or_kill().or(Some(LOST))
            }
        };
        let Some(status) = status else {
            return;
        };
        // Never over a status already recorded: an abort races the ordinary end, since
        // the hangup it sends is what makes the child exit, and `Session::shutdown`
        // reaps on its own thread.
        self.exited.held().get_or_insert(status);
        // Acknowledged on Emacs' behalf, because a wakeup still in flight would otherwise
        // swallow the one below, which is the last this session sends. Not `rearm`: the
        // byte goes out regardless of the throttle.
        self.notifier.acknowledge();
        self.notify();
    }

    /// The emulator, locked, for a thread that is not the reader.
    ///
    /// Every path that reaches [`Term`] from Emacs goes through here -- a drain, a
    /// resize, `cooked--feed', every accessor [`Session::term`] hands out -- so that the
    /// reader can see that somebody is waiting and cut its parse short; see
    /// [`Shared::feed`]. One helper rather than a claim raised at each call site, because
    /// the one call site that forgot would be the one whose latency nobody could explain.
    ///
    /// The reader must never call this. It would count itself as a waiter and yield to
    /// itself, which costs nothing but reads as a lie.
    fn term_for_lisp(&self) -> MutexGuard<'_, Term> {
        let _waiting = Waiting::on(&self.lisp_waiters);
        self.term.held()
    }

    /// Parse DATA into the terminal, decoding any picture in it with the lock dropped.
    ///
    /// Returns whether Emacs has something to draw, and the replies owed the child.
    ///
    /// The lock is released around each decode -- see `Term::feed_step` -- so Emacs never
    /// waits on the decode of a picture, and the parse itself is cut into
    /// [`PARSE_SLICE`]-sized pieces with [`Shared::lisp_waiters`] read between them, so a
    /// drain, a resize or a keystroke waits on one slice of parsing rather than on a
    /// whole read.
    ///
    /// Byte order is untouched: the slices are consecutive and each is parsed to
    /// completion before the next begins, and the parser is a state machine that carries
    /// a half-read escape sequence or UTF-8 character across the boundary exactly as it
    /// already carries one across the boundary between two reads.
    ///
    /// What a slice boundary does cost is the [`Term::woken`] comparison, which is a
    /// snapshot of counters that a drain resets. So the answer is accumulated per
    /// segment, a segment being the run between two releases of the lock: with nothing
    /// waiting and no picture to decode there is one segment and the answer is the
    /// whole-read comparison this always made, and where the lock was released the two
    /// halves are asked separately, because only the first half's changes are still on
    /// the counters a drain may have zeroed. That can only answer "drawable" where the
    /// single comparison would have said no -- never the other way round -- so the worst
    /// it costs is a wakeup for a read whose net effect was nothing.
    ///
    /// A drain landing between two slices is otherwise not observable. It sees a
    /// consistent [`Term`], because the lock says so, and half of a frame rather than all
    /// of it is what a drain landing between two *reads* already sees -- the child's
    /// writes are cut into 64KB pieces by the pty long before they are cut into 8KB
    /// pieces here. The one client that asks not to be drawn mid-frame says so with DEC
    /// mode 2026, and that is honoured on the notification side, not here: the marker
    /// arms `sync_until` and [`NotifyState::decide`] holds the wake byte back until the
    /// child ends the frame or [`SYNC_TIMEOUT`](crate::emu::term::SYNC_TIMEOUT) runs out.
    /// A drain the *user* asks for mid-frame was always served at once and still is.
    fn feed(&self, data: &[u8], hidden: bool) -> (bool, Vec<Event>) {
        let limit = self.backlog_limit.load(Ordering::Relaxed);
        let mut term = self.term.held();
        let mut progress = term.feed_start();
        let mut drawable = false;
        let mut offset = 0;
        while offset < data.len() {
            let slice = (offset + PARSE_SLICE).min(data.len());
            while offset < slice {
                match term.feed_step(&data[offset..slice]) {
                    Feed::Done => offset = slice,
                    Feed::Decode(job, consumed) => {
                        offset += consumed;
                        drawable |= term.woken(&progress, hidden, limit);
                        drop(term);
                        let decoded = job.run();
                        term = self.term.held();
                        progress = term.feed_start();
                        term.resume(decoded);
                    }
                }
            }
            if offset < data.len() && self.lisp_waiters.load(Ordering::SeqCst) > 0 {
                drawable |= term.woken(&progress, hidden, limit);
                drop(term);
                self.hand_over();
                term = self.term.held();
                progress = term.feed_start();
            }
        }
        drawable |= term.woken(&progress, hidden, limit);
        (drawable, term.take_outbound())
    }

    /// Wait, with the terminal lock dropped, for the thread that wanted it to have it.
    ///
    /// Dropping the mutex is not enough on its own. `std::sync::Mutex` makes no fairness
    /// promise, and on Linux the unlocking thread reliably wins the race to relock
    /// against the waiter it just woke, so a reader that dropped and immediately relocked
    /// would parse the next slice with the waiter still queued and the handoff would
    /// never happen. Yielding until the count goes to zero is what actually lets Emacs
    /// in; see [`HANDOFF_YIELDS`] for why it gives up rather than spinning forever.
    fn hand_over(&self) {
        for _ in 0..HANDOFF_YIELDS {
            if self.lisp_waiters.load(Ordering::SeqCst) == 0 {
                return;
            }
            std::thread::yield_now();
        }
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
    /// The pty hung up, so the child is on its way out -- though not always reapable
    /// yet, and not always even exiting; see [`Shared::linger_for_exit`].
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
        nix::sys::signal::kill(Pid::from_raw(pid), None)
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
    ///
    /// For the tests with a real child in them, which are the only ones left that wait on
    /// the wall clock; the notifier's own tests step [`TestClock`] instead and so have no
    /// deadline to stretch.
    fn patience(seconds: f64) -> Duration {
        Duration::from_secs_f64(seconds * crate::pty::timeout_scale())
    }

    /// A clock a test moves by hand, and the [`Clock`] the notifier reads it through.
    ///
    /// The pacing rules are a relation between deadlines rather than something that takes
    /// time, so each of the notifier's tests states one as a sequence of steps with
    /// [`TestClock::advance`] between them. Nothing there sleeps, so nothing there is a
    /// question about how loaded the machine is.
    #[derive(Clone)]
    struct TestClock(Arc<Mutex<Instant>>);

    impl TestClock {
        fn new() -> Self {
            Self(Arc::new(Mutex::new(Instant::now())))
        }

        /// The handle to put in [`Options`], reading the same instant this one moves.
        fn clock(&self) -> Clock {
            let at = Arc::clone(&self.0);
            Clock(Arc::new(move || *at.held()))
        }

        fn now(&self) -> Instant {
            *self.0.held()
        }

        fn advance(&self, by: Duration) {
            *self.0.held() += by;
        }
    }

    /// A notifier on a hand-stepped clock, with the wake pipe to watch it on.
    ///
    /// `Options` rather than the interval alone because the ceiling derives from the
    /// interval, and because every test here pins the gates it is not about out of the
    /// way.
    fn paced_notifier(options: Options) -> (Notifier, OwnedFd, TestClock) {
        let clock = TestClock::new();
        let (read, write) = pipe();
        let notifier = Notifier::new(
            write,
            &Options {
                clock: clock.clock(),
                ..options
            },
        );
        (notifier, read, clock)
    }

    /// Whether a wake byte is waiting on READ, taking it if so.
    ///
    /// [`woke_within`] with the waiting taken out: with the clock stopped nothing is on
    /// its way, so a byte is either on the pipe now or was never sent.
    fn woke(read: &OwnedFd) -> bool {
        nix::fcntl::fcntl(
            read.as_fd(),
            nix::fcntl::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
        )
        .expect("nonblock");
        let mut byte = [0u8; 1];
        matches!(nix::unistd::read(read.as_fd(), &mut byte), Ok(1))
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
            .flat_map(|row| row.runs.iter().map(|r| r.text.to_owned()))
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
        let start = Instant::now();
        let deadline = start + patience(10.0);
        while Instant::now() < deadline {
            let update = session.drain();
            collected.extend(
                update
                    .delta
                    .scrolled
                    .iter()
                    .map(|line| line.runs.iter().map(|r| r.text).collect::<String>()),
            );
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
        // Each drain wakes the reader through the interrupt, so a stalled reader resumes
        // at once and not at the next poll tick. Two hundred lines through a backlog of
        // one, resumed once per tick, would be twenty seconds.
        assert!(
            start.elapsed() < patience(3.0),
            "the reader waited out the tick rather than the drain: {:?}",
            start.elapsed()
        );
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
        let (notifier, read, clock) = paced_notifier(Options::default());
        let start = clock.now();
        // One drawable change -- the frame -- and then nothing but reads.
        notifier.fed(true, true);
        // Reads closer together than `QUIESCENCE`, which is what makes the pty never
        // quiet, and none of them drawable, so the ceiling the second change would arm is
        // never armed either. Answers whether the frame went out by ELAPSED past its one
        // change.
        let noise_until = |elapsed: Duration| {
            while clock.now() < start + elapsed {
                notifier.fed(false, true);
                notifier.flush();
                if woke(&read) {
                    return true;
                }
                clock.advance(QUIESCENCE / 2);
            }
            false
        };
        assert!(
            !noise_until(HOLD_CEILING - QUIESCENCE),
            "the frame was drawn before the {HOLD_CEILING:?} backstop it is held by"
        );
        assert!(
            noise_until(HOLD_CEILING + QUIESCENCE),
            "a client writing nothing drawable held its one drawn frame past the \
             {HOLD_CEILING:?} backstop; the hold is bounded from the frame's first \
             change, not from the last read"
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
        // Any two instants state the rule, and a cap of the emulator's own
        // [`SYNC_TIMEOUT`] would be indistinguishable from [`HOLD_CEILING`], which is the
        // same number. Forty milliseconds keeps the two apart.
        const FRAME: Duration = Duration::from_millis(40);
        let (notifier, read, clock) = paced_notifier(Options {
            // Out of the way, both of them: what releases the frame below has to be the
            // marker's own deadline and nothing else.
            quiescence: Duration::from_millis(1),
            frame_ceiling: Duration::from_secs(1),
            ..Options::with_min_redisplay_interval(Duration::from_millis(1))
        });
        let start = clock.now();
        notifier.fed(true, true);
        notifier.set_sync(Some(start + FRAME));

        // Half way through, a read that is drawable, is inside the held frame, and begins
        // another one.
        clock.advance(FRAME / 2);
        notifier.fed(true, true);
        notifier.set_sync(Some(clock.now() + FRAME));
        notifier.flush();
        assert!(
            !woke(&read),
            "the frame was drawn before its own marker expired"
        );

        clock.advance(FRAME / 2 + Duration::from_millis(1));
        notifier.flush();
        assert!(
            woke(&read),
            "a marker renewed mid-frame pushed the {FRAME:?} cap the first one set out to \
             {:?}; a later marker must leave that deadline where it is",
            FRAME + FRAME / 2
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
                session
                    .send(b"\n", Input::Other, &|| false)
                    .expect("release the second write");
            }
            Drain::AfterTheWrite => {
                session
                    .send(b"\n", Input::Other, &|| false)
                    .expect("release the second write");
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
    /// a drain that took a delta buys no second wake byte until Emacs says it has applied
    /// the first.
    ///
    /// This is the ordering the protocol rests on: if `drain` flushed, the window would
    /// cover taking the delta rather than applying it, which is what
    /// `min_redisplay_interval` paces.
    ///
    /// Unattended, so the reader's own tick backs off towards [`UNATTENDED_TICK_CAP`] rather than
    /// [`POLL_TIMEOUT_MS`]: the tick flushes unconditionally and would otherwise send the
    /// byte inside the patience below, which must not be mistaken for the re-arm. The
    /// second write is driven by input rather than a sleep so it cannot land before the
    /// first wakeup has been read.
    ///
    /// The wait after that input is the one part of this that is arithmetic rather than
    /// protocol: input resets the tick's backoff (see [`Shared::activity`]), so the drain
    /// has to land between two ticks of it, or a tick inside the patience below is read
    /// as the drain having flushed. Past [`RESAMPLE_DELAY`] and [`INTERACTION_WINDOW`] by
    /// construction, so neither brings a tick forward. Nothing can escape onto the pipe
    /// during the wait: every path to the wake descriptor is gated on `notified`, which
    /// only the drain below clears.
    #[test]
    fn a_drain_earns_no_second_wakeup_until_ready_says_the_drain_is_applied() {
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

        session
            .send(b"\n", Input::Other, &|| false)
            .expect("release the second write");
        // The window itself, plus a couple of eager ticks' slack for the reader to have
        // settled back onto the long one.
        // Past the window, and placed between two ticks of the backoff: after the
        // input and the output it releases, the quiet ticks fall at about 100, 300, 700
        // and 1500ms, so a drain at a second and a 200ms watch after it sit clear of
        // both neighbours.
        std::thread::sleep(INTERACTION_WINDOW + Duration::from_millis(500));
        session.drain();
        assert!(
            !woke_within(&read, Duration::from_millis(200)),
            "the second write was announced by the drain itself; the re-arm belongs to \
             `ready`, after Emacs has applied the delta"
        );

        session.ready();
        assert!(
            woke_within(&read, Duration::from_millis(500)),
            "`ready` must release the notification the drain deliberately withheld"
        );
        drop(session);
    }

    /// The redisplay interval the echo tests run at, long enough that a frame the interval
    /// holds cannot be mistaken for one sent at once, however loaded the machine is.
    const PACED: Duration = Duration::from_secs(3);

    /// A session running the shell SCRIPT at [`PACED`], with the frame its start-up prints
    /// already drained, so the interval is running when the test begins.
    fn paced_session(script: &str) -> (Session, OwnedFd) {
        let (session, read) = session_with(
            &["/bin/sh", "-c", script],
            Options::with_min_redisplay_interval(PACED),
        );
        assert!(
            woke_within(&read, patience(2.0)),
            "the child's start-up was never announced"
        );
        session.drain();
        session.ready();
        (session, read)
    }

    /// A keystroke's echo is drawn at once, although the last frame went out moments ago
    /// and the interval has most of its length still to run. See [`ECHO_WINDOW`].
    ///
    /// The echo is the tty's own, one write and then silence, as a line editor's is.
    #[test]
    fn a_keystroke_is_echoed_without_waiting_out_the_interval() {
        let (session, read) = paced_session("printf a; read -r _; sleep 5");
        session
            .send(b"b", Input::Keyboard, &|| false)
            .expect("type");
        assert!(
            woke_within(&read, patience(0.5)),
            "the echo of a key waited on the redisplay interval"
        );
        assert!(rendered(&session.drain()).contains("ab"));
    }

    /// A mouse report is not a keystroke, and the child's answer to it waits out the
    /// interval like any other output: under mode 1003 a pointer sweep sends a report per
    /// motion event, and a frame per report is what the interval is there to prevent.
    ///
    /// The drain afterwards shows the child did answer, so the silence is the interval and
    /// not a child that wrote nothing.
    #[test]
    fn a_mouse_report_waits_out_the_interval() {
        let (session, read) = paced_session("printf a; read -r _; sleep 5");
        session
            .send(b"\x1b[<0;1;1M", Input::Other, &|| false)
            .expect("report");
        assert!(
            !woke_within(&read, Duration::from_millis(500)),
            "the answer to a mouse report skipped the redisplay interval"
        );
        assert!(rendered(&session.drain()).contains("[<0;1;1M"));
    }

    /// A keystroke to a buffer no window shows wakes nothing early, even when what the
    /// child writes back is an event that does wake a hidden buffer: there is no echo on
    /// screen to hurry. See [`Notifier::fed`].
    #[test]
    fn a_keystroke_to_a_hidden_session_waits_out_the_interval() {
        let (session, read) = paced_session("printf '\\a'; read -r _; printf '\\a'; sleep 5");
        session.set_hidden(true);
        session
            .send(b"\n", Input::Keyboard, &|| false)
            .expect("type");
        assert!(
            !woke_within(&read, Duration::from_millis(500)),
            "a hidden session was woken early for a keystroke"
        );
        assert!(
            session.drain_hidden().delta.events.contains(&Event::Bell),
            "the child never rang, so the silence proves nothing"
        );
    }

    /// The window a keystroke opens waives one frame: the first drawable read takes it,
    /// and the read after that waits out the interval as usual. An echo window nobody
    /// used waives nothing once it has expired. Driven through the notifier, since a
    /// child cannot be made to split its output across reads on demand.
    ///
    /// The reader's tick is checked on the echo as well. A tick that slept out the
    /// interval would leave a lone echo, which nothing else wakes the reader for, to the
    /// next resample some 50ms later.
    #[test]
    fn a_keystroke_waives_the_interval_for_one_frame_only() {
        let (notifier, read, clock) = paced_notifier(Options::with_min_redisplay_interval(PACED));
        // Each flush is made past `QUIESCENCE`, so the throttle is the only gate left.
        let frame = || {
            notifier.fed(true, true);
            clock.advance(QUIESCENCE * 4);
            notifier.flush();
            let sent = woke(&read);
            notifier.acknowledge();
            sent
        };
        assert!(frame(), "the first frame has no interval to wait on");

        notifier.expect_echo();
        notifier.fed(true, true);
        let tick = notifier.poll_wait(PACED);
        assert!(
            tick <= QUIESCENCE,
            "the reader would sleep {tick:?} before flushing an echo"
        );
        assert!(frame(), "the echo waited on the interval");
        assert!(
            !frame(),
            "a second read after one keystroke skipped the interval too"
        );

        notifier.expect_echo();
        clock.advance(ECHO_WINDOW + Duration::from_millis(1));
        assert!(!frame(), "an expired echo window still waived the interval");
    }

    /// An echo skips the redisplay interval and still waits for the pty to go quiet.
    ///
    /// The two gates differ in kind, which is why only one of them is waived. The throttle
    /// is a pure clock, and skipping it is what keeps a keystroke from waiting out an
    /// interval the *previous* echo started. [`QUIESCENCE`] is not a clock but the question
    /// of whether the child has finished writing, and a line editor redrawing its line in
    /// several writes is exactly what it is there for -- so the echo waits on it like
    /// anything else. See [`NotifyState::echo`].
    #[test]
    fn an_echo_waives_the_throttle_and_not_the_quiescence_wait() {
        /// Wide enough to be stepped either side of, with `min_interval` far above it so
        /// the throttle is the gate the waiver is measured against.
        const QUIET: Duration = Duration::from_millis(10);
        let (notifier, read, clock) = paced_notifier(Options {
            quiescence: QUIET,
            ..Options::with_min_redisplay_interval(PACED)
        });

        // A frame first, so there is a `last` for the throttle to be measured from.
        notifier.fed(true, true);
        clock.advance(QUIET * 2);
        notifier.flush();
        assert!(woke(&read), "the first frame has no interval to wait on");
        notifier.acknowledge();

        notifier.expect_echo();
        notifier.fed(true, true);
        notifier.flush();
        assert!(
            !woke(&read),
            "an echo was drawn before the pty went quiet, so the child may be half way \
             through redrawing its line"
        );

        clock.advance(QUIET * 2);
        notifier.flush();
        assert!(
            woke(&read),
            "the echo waited out the {PACED:?} interval the frame before it started"
        );
    }

    /// The frame ceiling is armed by a frame's *second* drawable change, not its first.
    ///
    /// One cursor move followed by a long silent image transfer has nothing further to
    /// show, and firing on it would draw the cursor on top of a picture that has not
    /// arrived. A client genuinely streaming changes produces its second within
    /// microseconds and so arms the ceiling at once; until it does, the only bound on the
    /// hold is [`HOLD_CEILING`], which is far away here. See
    /// [`NotifyState::frame_ceiling`].
    #[test]
    fn the_frame_ceiling_is_armed_by_the_second_change() {
        const CEILING: Duration = Duration::from_millis(20);
        let (notifier, read, clock) = paced_notifier(Options {
            // Never quiet, so the ceiling is the only thing that can release the frame,
            // and no interval worth speaking of, so the throttle is not it either.
            quiescence: Duration::from_secs(30),
            frame_ceiling: CEILING,
            ..Options::with_min_redisplay_interval(Duration::from_millis(1))
        });

        notifier.fed(true, true);
        clock.advance(CEILING * 2);
        notifier.flush();
        assert!(
            !woke(&read),
            "one change armed the ceiling; a lone cursor move would be drawn over the \
             image transfer behind it"
        );

        notifier.fed(true, true);
        notifier.flush();
        assert!(
            !woke(&read),
            "the second change was drawn at once instead of arming the ceiling"
        );

        clock.advance(CEILING + Duration::from_millis(1));
        notifier.flush();
        assert!(
            woke(&read),
            "a client streaming changes was never drawn at the {CEILING:?} ceiling its \
             second change armed"
        );
    }

    /// An announcement releases a held frame, and the one deadline it leaves alone is the
    /// client's own.
    ///
    /// A termios change, a full backlog or an exited child is nothing the child will
    /// finish writing, so the quiescence wait and the ceilings it arms are cleared
    /// outright: `getpass` turning echo off just after printing its prompt must not wait
    /// on the rest of an update. DEC mode 2026 is the exception, and the reason `announce`
    /// clears three deadlines and not the fourth -- there the client has said in as many
    /// words that its screen is mid-frame. See [`Notifier::announce`].
    #[test]
    fn an_announcement_releases_a_held_frame_but_not_a_synchronized_one() {
        const FRAME: Duration = Duration::from_millis(40);
        let (notifier, read, clock) = paced_notifier(Options {
            // Never quiet: nothing but the announcement can release this frame.
            quiescence: Duration::from_secs(30),
            ..Options::with_min_redisplay_interval(Duration::from_millis(1))
        });

        notifier.fed(true, true);
        notifier.flush();
        assert!(!woke(&read), "a frame still being written was drawn");
        notifier.announce();
        assert!(
            woke(&read),
            "an announcement waited out a quiescence hold it had just cleared"
        );
        notifier.acknowledge();

        // The same again, with the client's own marker set over it.
        notifier.fed(true, true);
        notifier.set_sync(Some(clock.now() + FRAME));
        notifier.announce();
        assert!(
            !woke(&read),
            "an announcement drew over a frame the client had marked as unfinished"
        );

        clock.advance(FRAME + Duration::from_millis(1));
        notifier.flush();
        assert!(
            woke(&read),
            "the announcement was lost rather than retried when the marker expired"
        );
    }

    /// A key held down against a child writing flat out adds at most one frame per key,
    /// and does add them.
    ///
    /// The upper bound is the waiver's failure mode: an `echo` that was never cleared
    /// would draw the child at its own write rate, a frame every few milliseconds, instead
    /// of at the interval. The lower bound is the waiver working, the echo of each key
    /// drawn without waiting on the frame before it.
    ///
    /// The child pauses a few milliseconds between writes, so each write passes
    /// [`QUIESCENCE`] and only the interval stands between it and a frame. It is bounded,
    /// so it dies on its own if the teardown ever stops working.
    #[test]
    fn a_key_held_down_beside_a_busy_child_adds_at_most_a_frame_a_key() {
        const INTERVAL: Duration = Duration::from_millis(100);
        const KEY_EVERY: Duration = Duration::from_millis(20);
        const RUN: Duration = Duration::from_secs(1);
        let (session, read) = session_with(
            &[
                "/bin/sh",
                "-c",
                "i=0; while [ $i -lt 3000 ]; do printf .; sleep 0.003; i=$((i+1)); done",
            ],
            Options::with_min_redisplay_interval(INTERVAL),
        );
        nix::fcntl::fcntl(
            read.as_fd(),
            nix::fcntl::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
        )
        .expect("nonblock");
        let start = Instant::now();
        let mut next_key = start;
        let (mut keys, mut wakes) = (0u32, 0u32);
        let mut byte = [0u8; 1];
        while start.elapsed() < RUN {
            if Instant::now() >= next_key {
                session
                    .send(b"j", Input::Keyboard, &|| false)
                    .expect("type");
                keys += 1;
                next_key += KEY_EVERY;
            }
            let mut fds = [PollFd::new(read.as_fd(), PollFlags::POLLIN)];
            let wait = next_key.saturating_duration_since(Instant::now());
            let _ = crate::platform::poll(&mut fds, wait);
            if let Ok(1) = nix::unistd::read(read.as_fd(), &mut byte) {
                wakes += 1;
                session.drain();
                session.ready();
            }
        }
        let cadence = (RUN.as_millis() / INTERVAL.as_millis()) as u32;
        assert!(
            wakes <= cadence + keys + 2,
            "{wakes} wakes for {keys} keys in {RUN:?}; the interval allows {cadence} and \
             each key at most one more"
        );
        assert!(
            wakes > 2 * cadence,
            "{wakes} wakes for {keys} keys in {RUN:?}; the interval alone allows \
             {cadence}, so the keys' echoes were not drawn early"
        );
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

        session
            .send(b"\n", Input::Other, &|| false)
            .expect("release the write");
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

    /// A write the child is not taking ends when STOP says so, not at the deadline.
    ///
    /// Raw mode, so the line discipline holds what it is given rather than discarding
    /// past a line, and a sleep that reads nothing, so the pty fills and `write` has to
    /// wait. The stop check is the third question asked, which is well inside
    /// `WRITE_TIMEOUT` and well outside a write that never waited at all.
    #[test]
    fn a_stop_check_cuts_a_blocked_write_short() {
        let (session, _read) = session(&["/bin/sh", "-c", "stty raw -echo; sleep 300"]);
        wait_for(&session, |u| u.mode == Mode::Raw);
        let asked = std::cell::Cell::new(0);
        let stop = || {
            asked.set(asked.get() + 1);
            asked.get() >= 3
        };
        let start = Instant::now();
        let result = session.send(&vec![b'x'; 1 << 20], Input::Other, &stop);
        assert_eq!(result, Err(crate::error::Error::Interrupted));
        assert!(
            start.elapsed() < WRITE_TIMEOUT / 2,
            "took {:?}, which is the deadline and not the stop",
            start.elapsed()
        );
    }

    /// A paste bigger than the backlog must not deadlock against the reader's throttle.
    ///
    /// `send` blocks Emacs' thread in `Pty::write`, so nothing drains while it waits. A
    /// child that echoes the paste back fills the backlog, the reader stops pulling from
    /// the pty to let the child block, and the child then stops reading -- so the write
    /// waits out `WRITE_TIMEOUT` and the paste is cut short with an error. A backlog of
    /// one line and a paste of a few thousand is the shortest way to that state.
    ///
    /// Raw mode with no echo so the line discipline neither chops the paste at
    /// `MAX_INPUT` nor doubles it; `cat` alone is what sends it back.
    #[test]
    fn a_paste_larger_than_the_backlog_is_not_stalled_by_the_throttle() {
        const LINES: usize = 8192;
        let (session, _read) =
            session_with_backlog(&["/bin/sh", "-c", "stty raw -echo; exec cat"], 1);
        wait_for(&session, |u| u.mode == Mode::Raw);
        let paste = b"paste\r\n".repeat(LINES);
        let start = Instant::now();
        let result = session.send(&paste, Input::Other, &|| false);
        assert_eq!(
            result,
            Ok(()),
            "the paste stalled against the backlog throttle and timed out"
        );
        assert!(
            start.elapsed() < WRITE_TIMEOUT / 2,
            "the paste took {:?}, which is the write deadline and not the child",
            start.elapsed()
        );
    }

    #[test]
    fn input_round_trips_through_the_pty() {
        let (session, _read) = session(&["/bin/cat"]);
        session
            .send(b"ping\n", Input::Other, &|| false)
            .expect("send");
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
    /// A quiet session's tick backs off, and output brings it straight back.
    ///
    /// Attended throughout: the backoff is what an idle terminal under the user's eyes
    /// costs, and it must not be paid for as staleness once the child speaks again.
    #[test]
    fn an_idle_tick_backs_off_and_output_resets_it() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 1; echo hi; sleep 5"]);
        let base = Duration::from_millis(u64::from(POLL_TIMEOUT_MS));
        std::thread::sleep(Duration::from_millis(800));
        let backed_off = session.shared.base_poll_wait();
        assert!(
            backed_off > base,
            "still at the base after 800ms of silence"
        );
        assert!(backed_off <= ATTENDED_TICK_CAP);
        wait_for(&session, |u| rendered(u).contains("hi"));
        assert_eq!(session.shared.base_poll_wait(), base);
    }

    #[test]
    fn an_unattended_session_still_observes_a_silent_mode_change() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 0.2; stty -echo; sleep 5"]);
        session.set_attended(false);
        assert_eq!(session.mode(), Mode::Cooked);
        // Generously past `UNATTENDED_TICK_CAP`; the assertion is that it arrives at
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
        session.send(b"j", Input::Other, &|| false).expect("send");
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
        let base = Duration::from_millis(u64::from(POLL_TIMEOUT_MS));
        // Long enough for a few ticks to find nothing: 100, 200 and 400ms.
        std::thread::sleep(Duration::from_millis(800));
        assert!(
            session.shared.base_poll_wait() > base,
            "an unattended session nobody has touched must have backed off"
        );

        session.send(b"j", Input::Other, &|| false).expect("send");
        assert_eq!(
            session.shared.base_poll_wait(),
            base,
            "input must buy the eager tick back"
        );

        std::thread::sleep(INTERACTION_WINDOW + Duration::from_millis(50));
        assert!(
            session.shared.base_poll_wait() > base,
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
        session.send(b"j", Input::Other, &|| false).expect("send");
        assert_eq!(session.shared.base_poll_wait(), attended);
    }

    /// Attention changes the tick and nothing else. The pty is read on `POLLIN`, which
    /// no timeout defers, so output must arrive at the same speed either way.
    #[test]
    fn an_unattended_session_still_renders_output_promptly() {
        let (session, _read) = session(&["/bin/cat"]);
        session.set_attended(false);
        let start = Instant::now();
        session
            .send(b"ping\n", Input::Other, &|| false)
            .expect("send");
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
        let pid = session.pid().as_raw();
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

    /// The hangup goes to the shell, not to whatever it is running.
    ///
    /// An interactive bash puts `sleep` in a process group of its own and makes that the
    /// foreground. Hanging up the foreground group killed the sleep and left bash to
    /// carry on and exit 0 in its own time; hanging up bash's group runs its HUP trap,
    /// which is the exit status a shell saving its history on the way out would have.
    #[test]
    fn shutdown_hangs_up_the_shell_rather_than_its_foreground_job() {
        if !std::path::Path::new("/bin/bash").exists() {
            eprintln!("skipping: no /bin/bash");
            return;
        }
        let (session, _read) = session(&[
            "/bin/bash",
            "--norc",
            "-i",
            "-c",
            "trap 'exit 3' HUP; sleep 300; exit 9",
        ]);
        // Let bash reach the sleep and hand it the foreground; the trap is installed
        // first, so a hangup any earlier still lands on the shell.
        wait_for_within(&session, 5.0, |_| {
            session
                .shared
                .pty
                .foreground()
                .is_ok_and(|fg| fg != session.pid())
        });
        assert!(session.shutdown());
        assert_eq!(session.drain().exit, Some(3));
    }

    /// An interrupt reaches the foreground group, whichever way the platform sends it.
    ///
    /// `sh -c` with two commands keeps the shell in the foreground with `sleep` in its
    /// group, so SIGINT interrupts the sleep and the shell's trap decides the status.
    #[test]
    fn an_interrupt_reaches_the_foreground_group() {
        let (session, _read) = session(&["/bin/sh", "-c", "trap 'exit 5' INT; sleep 300; exit 9"]);
        std::thread::sleep(Duration::from_millis(150));
        session.signal(Signal::SIGINT).expect("signal");
        let update = wait_for(&session, |u| u.exit.is_some());
        assert_eq!(update.exit, Some(5));
    }

    /// A reader that leaves with the child still there ends the session anyway.
    ///
    /// Left to itself, the child kept running with nothing reading its output and
    /// `alive` answering yes for good. Now it is hung up, killed if that is what it
    /// takes, and the status lands where any exit would.
    #[test]
    fn an_aborted_reader_still_ends_the_session() {
        // `exec`, so the ignored disposition is the sleep's own and the hangup is
        // refused by the only process there is.
        let (session, _read) = session(&["/bin/sh", "-c", "trap '' HUP; exec sleep 300"]);
        let pid = session.pid().as_raw();
        std::thread::sleep(Duration::from_millis(150));
        session.shared.finish(Ended::Aborted);
        assert!(!session.alive());
        assert_eq!(alive(pid), Err(Errno::ESRCH));
        assert_eq!(session.drain().exit, Some(128 + Signal::SIGKILL as i32));
    }

    /// A child that closes its tty and keeps running is waited out, not killed.
    ///
    /// The shell closes the last descriptors on the slave and sleeps, so the master hangs
    /// up while the direct child is still running and still ours to reap. The first reap
    /// has nothing to collect, and what used to follow was nothing at all: no status, no
    /// wakeup, and `alive` answering yes for good with the reader already gone. Now the
    /// session stays alive for exactly as long as the child does -- it is alive -- and
    /// reports the status the child really exits with, 7 rather than a signal, which is
    /// what says it was waited for rather than hung up on and killed.
    #[test]
    fn a_child_that_closed_its_tty_is_waited_out_rather_than_killed() {
        // The `echo` is so the test can wait for the child to be up; the sleep outlasts
        // `REAP_PATIENCE` twice over, which is what leaves the first reap empty-handed.
        let (session, read) = session(&[
            "/bin/sh",
            "-c",
            "echo ready; exec 0<&- 1>&- 2>&-; sleep 1; exit 7",
        ]);
        let pid = session.pid().as_raw();
        wait_for(&session, |u| rendered(u).contains("ready"));
        assert!(
            session.alive(),
            "the session gave up on a child that is still running"
        );
        // The wakeups for the output so far, so the one asserted below is the exit's own.
        while woke_within(&read, Duration::from_millis(50)) {}
        let update = wait_for_within(&session, 10.0, |u| u.exit.is_some());
        assert_eq!(update.exit, Some(7), "the child's own exit status");
        assert_eq!(
            alive(pid),
            Err(Errno::ESRCH),
            "the child is still there after its exit was reported"
        );
        assert!(
            woke_within(&read, patience(1.0)),
            "the session ended without waking Emacs"
        );
    }

    /// A panic on the reader thread ends the session as an abort does, rather than
    /// leaving a live child on a pty nobody reads and a buffer nothing will wake.
    ///
    /// The child ignores SIGHUP so that the kill has to be the one that ends it, which is
    /// what shows the `finish` ran at all: with the panic merely unwinding the thread,
    /// `sleep` would still be running and `alive` would still say so.
    #[test]
    fn a_panicking_reader_ends_the_session_and_wakes_emacs() {
        let (session, read) = session(&["/bin/sh", "-c", "trap '' HUP; echo hi; exec sleep 300"]);
        let pid = session.pid().as_raw();
        // Set before the child's first write can be read, so that write is the one that
        // panics; the echo is what makes sure there is a read to panic on.
        session.shared.panic_on_read.store(true, Ordering::SeqCst);
        // The wake byte is `finish`'s: nothing was parsed, so nothing else sends one.
        assert!(
            woke_within(&read, patience(5.0)),
            "the session ended without waking Emacs"
        );
        assert!(
            !session.alive(),
            "the session is still alive after its reader died"
        );
        assert_eq!(
            alive(pid),
            Err(Errno::ESRCH),
            "the child outlived its reader"
        );
        assert_eq!(session.drain().exit, Some(128 + Signal::SIGKILL as i32));
    }

    #[test]
    fn shutdown_survives_a_child_that_ignores_sighup() {
        let (session, _read) = session(&["/bin/sh", "-c", "trap '' HUP; sleep 300"]);
        let pid = session.pid().as_raw();
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
    /// A kill landing in the middle of a picture's decode must not wait for it.
    ///
    /// [`Session::shutdown`] runs on the thread holding the `emacs_env`, and `Drop` reaches
    /// it from the garbage collector. A reader inside `job.run()` holds no lock and checks
    /// no flag, so joining it there parked Emacs for the length of a decode -- a stall
    /// rather than a hang, bounded by `sixel::MAX_PIXELS` and the kitty caps, and on the
    /// interactive thread.
    ///
    /// The picture is a sixel of just under [`MAX_PIXELS`](crate::emu::sixel::MAX_PIXELS),
    /// and the child prints a mark and then waits, so the kill below lands as the decode
    /// begins rather than after it. Measured on the machine this was written on: about a
    /// millisecond detached, and 175 to 185 joined.
    ///
    /// The child is still reaped: `kill(pid, 0)` answering `ESRCH` is the pid gone for
    /// good rather than a zombie nobody collected.
    #[test]
    fn a_kill_during_a_picture_decode_does_not_wait_for_it() {
        // 2048 by 1020, a row of `~` filling all six pixels of each band. Doubled up in the
        // shell and written by `printf`, a builtin, so no argument list ever carries it.
        let script = r#"
            t='~'
            i=0; while [ $i -lt 11 ]; do t=$t$t; i=$((i+1)); done
            printf 'GO\n'
            sleep 0.05
            printf '\033Pq"1;1;2048;1020'
            i=0; while [ $i -lt 170 ]; do printf '#1%s$-' "$t"; i=$((i+1)); done
            printf '\033\\'
            sleep 5
        "#;
        let (session, _read) = session(&["/bin/sh", "-c", script]);
        let pid = session.pid().as_raw();

        // Polled tightly rather than through `wait_for`, whose 20ms step is most of the
        // window the wait below is aiming at.
        let deadline = Instant::now() + patience(5.0);
        while Instant::now() < deadline {
            if rendered(&session.drain()).contains("GO") {
                break;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        // The child then waits 50ms and spends a few more writing the picture.
        std::thread::sleep(patience(0.06));

        let start = Instant::now();
        assert!(
            session.shutdown(),
            "this call must be the one that ended it"
        );
        assert!(
            start.elapsed() < patience(0.05),
            "the kill waited {:?} on the reader; a decode in flight must not park Emacs' \
             thread",
            start.elapsed()
        );
        // Detaching the reader must not cost the invariant the join used to give for
        // free. `shutdown` returning is the moment Lisp asks, and a session that answered
        // yes here would leave a killed buffer believing its child was still running.
        assert!(
            !session.alive(),
            "a session shut down must not answer alive"
        );

        let deadline = Instant::now() + patience(5.0);
        while Instant::now() < deadline {
            if alive(pid).is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        panic!("the child was left unreaped");
    }

    /// Finalising a handle nobody killed must not park Emacs' garbage collector.
    ///
    /// `Drop` is reached from a collection, at a moment no Lisp asked for, and it used to
    /// run the whole of `shutdown`: for a child that ignores SIGHUP that is `HANGUP_GRACE`
    /// and then `KILL_GRACE`, better than half a second with all of Emacs stopped. It now
    /// hangs up and leaves the grace to the reader thread, which is still there and still
    /// has to kill and reap the child -- the second half of this test.
    #[test]
    fn dropping_a_session_hands_the_grace_to_the_reader() {
        let (session, _read) = session(&["/bin/sh", "-c", "trap '' HUP; sleep 300"]);
        let pid = session.pid().as_raw();
        // Long enough for the shell to have installed the trap, so the hangup below is one
        // the child really does ignore.
        std::thread::sleep(Duration::from_millis(150));
        let start = Instant::now();
        drop(session);
        let elapsed = start.elapsed();
        assert!(
            elapsed < patience(0.010),
            "the drop took {elapsed:?}, which is the grace and not a hangup"
        );
        let deadline = Instant::now() + patience(5.0);
        while Instant::now() < deadline {
            // ESRCH rather than a zombie: the reader killed the child *and* collected it.
            if alive(pid) == Err(Errno::ESRCH) {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        panic!("the child outlived the handle nobody waited for");
    }

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

    /// Emacs' thread gets the terminal while a read is still being parsed, not after.
    ///
    /// The mechanism [`PARSE_SLICE`] and [`Shared::hand_over`] describe, stated as the
    /// thing it is for. A waiter takes the lock over and over through
    /// [`Session::term`] -- the same [`Shared::term_for_lisp`] a drain, a resize and
    /// every accessor go through -- while [`Shared::feed`] parses two megabytes, and
    /// records the backlog it found each time. A backlog strictly between nothing and
    /// the finished total is an acquisition that landed in the middle of the parse,
    /// which is exactly what could not happen before: one `feed` held the lock from the
    /// first byte to the last, so every acquisition saw either the backlog before it or
    /// the backlog after it and nothing in between.
    ///
    /// That assertion is about an ordering and not about a duration, so it does not care
    /// how loaded the machine is. The wait is asserted too, against half of the parse
    /// this test measured for itself rather than against a figure written down here --
    /// the unsliced wait is the whole parse, so half of it tells the two apart with a
    /// factor of a hundred of slack for a descheduled waiter.
    ///
    /// `feed` is called directly rather than through a child flooding the pty because
    /// the reader's read size is the pty's business: a child that hands it four
    /// kilobytes at a time would never reach a slice boundary, and the test would go
    /// quietly green with the slicing deleted. This is the reader's own call, with the
    /// reader's own argument.
    #[test]
    fn a_waiter_takes_the_terminal_mid_parse() {
        const LINES: usize = 36_000;
        let data: Vec<u8> = (0..LINES)
            .flat_map(|i| {
                format!("line {i:06} the quick brown fox jumps over the lazy dog\r\n").into_bytes()
            })
            .collect();
        // A child that says nothing, so the only parse in flight is the one below.
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 30"]);

        let parsing = AtomicBool::new(true);
        let (elapsed, drawable, seen) = std::thread::scope(|scope| {
            let waiter = scope.spawn(|| {
                let mut seen: Vec<(usize, Duration)> = Vec::new();
                while parsing.load(Ordering::SeqCst) {
                    let asked = Instant::now();
                    let term = session.term();
                    let waited = asked.elapsed();
                    seen.push((term.backlog(), waited));
                    drop(term);
                    std::thread::yield_now();
                }
                seen
            });
            let start = Instant::now();
            let (drawable, outbound) = session.shared.feed(&data, false);
            let elapsed = start.elapsed();
            parsing.store(false, Ordering::SeqCst);
            assert!(outbound.is_empty(), "plain text owes the child nothing");
            (elapsed, drawable, waiter.join().expect("waiter"))
        });

        assert!(drawable, "thirty-six thousand lines are worth drawing");
        let total = session.term().backlog();
        let mid = seen
            .iter()
            .filter(|(backlog, _)| (1..total).contains(backlog))
            .count();
        assert!(
            mid > 0,
            "no acquisition landed mid-parse: {} tries against a final backlog of {total}",
            seen.len()
        );
        let worst = seen
            .iter()
            .map(|(_, waited)| *waited)
            .max()
            .expect("the waiter ran at least once");
        assert!(
            worst < elapsed / 2,
            "waited {worst:?} for the lock against a {elapsed:?} parse"
        );

        // And the slicing lost nothing: every line the parse was given is in the
        // scrollback, in order, none of them cut in two at a slice boundary.
        let update = session.drain();
        let scrolled: Vec<String> = update
            .delta
            .scrolled
            .iter()
            .map(|line| line.runs.iter().map(|run| run.text).collect::<String>())
            .collect();
        assert!(
            scrolled.len() + 24 >= LINES,
            "{} lines scrolled off, {LINES} fed",
            scrolled.len()
        );
        let wrong = scrolled.iter().enumerate().find(|(i, line)| {
            line.trim_end() != format!("line {i:06} the quick brown fox jumps over the lazy dog")
        });
        assert!(
            wrong.is_none(),
            "line out of order or cut in two: {wrong:?}"
        );
    }
}
