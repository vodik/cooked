//! A running child: pty, emulator, and the reader thread that couples them to Emacs.
//!
//! Emacs' module functions may only be called from the thread holding an `emacs_env`, so
//! the reader never touches Lisp. It parses into the shared [`Term`] and pokes a pipe
//! descriptor obtained from `open_channel`; Emacs' filter then drains on the main thread.

use crate::emu::{self, Delta, Term};
use crate::pty::{Mode, Pid, Pty, Winsize};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{SigSet, Signal};
use std::ffi::OsStr;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

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
    /// A `resize` that arrived before the child had opened its slave, for the reader
    /// thread to retry. See `Session::resize`.
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
    /// Floor on how often the wake pipe is written to, regardless of how fast output
    /// arrives. Without one, a program that rewrites the same line rapidly — a spinner, a
    /// progress meter — drives one full Emacs redisplay per write, which is a lot more
    /// redraws than any of them are actually meant to be seen at and shows up as flicker.
    /// No matching ceiling is needed the way `eat-maximum-latency` provides one: `Term`
    /// always holds the latest state regardless of whether a wakeup was sent for it, and
    /// `flush_notify` is retried every reader-thread tick (bounded by `POLL_TIMEOUT_MS`
    /// even when no new output arrives), so a throttled notification is never stranded.
    min_redisplay_interval: std::time::Duration,
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
    ) -> io::Result<Self> {
        // Take ownership of the wake descriptor and mark it close-on-exec *before*
        // forking. `open_channel` hands it over without FD_CLOEXEC (verified: children
        // showed it in /proc/self/fd), so a child would otherwise inherit the write end
        // of the pipe Emacs watches — free to poke our redisplay, and keeping the pipe
        // from ever reaching EOF.
        let wake = unsafe { OwnedFd::from_raw_fd(wake) };
        nix::fcntl::fcntl(wake.as_fd(), nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC))
            .map_err(|e| io::Error::from_raw_os_error(e as i32))?;

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
            min_redisplay_interval,
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

        Ok(Self { shared, reader: Mutex::new(Some(reader)), wake: Mutex::new(Some(wake)) })
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
        drop(self.wake.lock().unwrap_or_else(|e| e.into_inner()).take());
        if let Some(reader) = self.reader.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = reader.join();
        }

        // The reader is joined, so this sees its final word on the matter. `Some` means it
        // already reaped and the pid is no longer ours to signal.
        let mut exited = self.shared.exited.lock().unwrap_or_else(|e| e.into_inner());
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
            delta: self.shared.term.lock().unwrap_or_else(|e| e.into_inner()).drain(),
            mode: self.shared.load_mode(),
            exit: *self.shared.exited.lock().unwrap_or_else(|e| e.into_inner()),
        }
    }

    pub fn send(&self, bytes: &[u8]) -> io::Result<()> {
        self.shared.pty.write(bytes)
    }

    /// Resize the emulator and, if the child is already attached, the pty itself.
    ///
    /// `Pty::resize` is a single, non-blocking attempt — this runs on the thread holding
    /// the `emacs_env`, so it must never wait out a retry. Immediately after `spawn`, before
    /// the child has opened its slave, that attempt fails with `ENOTTY`; rather than
    /// surface that to the caller (or block until it clears), the requested size is stashed
    /// for the reader thread's already-running loop to apply once the pty is ready — the
    /// same "not yet, try again soon" shape `sample_mode` already uses for the same
    /// underlying transient.
    pub fn resize(&self, size: Winsize) -> io::Result<()> {
        self.shared
            .term
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .resize(size.rows.into(), size.cols.into());
        match self.shared.pty.resize(size) {
            Err(e) if e.raw_os_error() == Some(libc::ENOTTY) => {
                *self.shared.pending_resize.lock().unwrap_or_else(|e| e.into_inner()) = Some(size);
                Ok(())
            }
            result => result,
        }
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

    pub fn alive(&self) -> bool {
        self.shared.exited.lock().is_ok_and(|e| e.is_none())
    }

    /// The last non-blank line — the prompt text for a [`Mode::Secret`] read.
    pub fn trailing_text(&self) -> Option<String> {
        self.shared.term.lock().ok()?.trailing_text()
    }

    pub fn bracketed_paste(&self) -> bool {
        self.shared.term.lock().is_ok_and(|t| t.bracketed_paste())
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

fn read_loop(shared: &Arc<Shared>, wake: BorrowedFd<'_>) {
    block_sigpipe();
    let mut buf = vec![0u8; READ_CHUNK];

    while !shared.shutdown.load(Ordering::SeqCst) {
        let mut fds = [
            PollFd::new(shared.pty.as_fd(), PollFlags::POLLIN),
            PollFd::new(shared.quit.read.as_fd(), PollFlags::POLLIN),
        ];
        match poll(&mut fds, PollTimeout::from(POLL_TIMEOUT_MS)) {
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
        if shared.term.lock().is_ok_and(|term| term.backlog() >= emu::BACKLOG_HIGH_WATER) {
            announce(shared, wake);
            std::thread::sleep(std::time::Duration::from_millis(2));
            continue;
        }

        match shared.pty.read(&mut buf) {
            Ok([]) => return finish(shared, wake, Ended::ChildGone),
            Ok(data) => {
                shared.term.lock().unwrap_or_else(|e| e.into_inner()).feed(data);
                // A child that changes mode almost always writes at the same moment, so
                // re-sampling here is what makes the common case feel instantaneous.
                sample_mode(shared);
                announce(shared, wake);
            }
            // EIO is how Linux reports the last slave closing.
            Err(e) if e.raw_os_error() == Some(libc::EIO) => return finish(shared, wake, Ended::ChildGone),
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
    let Some(status) = shared.pty.reap(patience) else { return };
    *shared.exited.lock().unwrap_or_else(|e| e.into_inner()) = Some(status);
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

/// Retry a `resize` stashed by `Session::resize`, clearing it once it lands.
fn apply_pending_resize(shared: &Arc<Shared>) {
    let mut pending = shared.pending_resize.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(size) = *pending
        && shared.pty.resize(size).is_ok()
    {
        *pending = None;
    }
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
    let mut last = shared.last_notified.lock().unwrap_or_else(|e| e.into_inner());
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
    use crate::emu::Event;
    use nix::errno::Errno;
    use std::time::{Duration, Instant};

    /// `kill(pid, 0)` only probes for existence. ESRCH means the pid is gone for good.
    fn alive(pid: i32) -> nix::Result<()> {
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None)
    }

    fn pipe() -> (OwnedFd, OwnedFd) {
        nix::unistd::pipe().expect("pipe")
    }

    fn session(argv: &[&str]) -> (Session, OwnedFd) {
        let (read, write) = pipe();
        let size = Winsize { rows: 24, cols: 80 };
        let fd = std::os::fd::IntoRawFd::into_raw_fd(write);
        (
            Session::spawn(argv, &[("TERM", "xterm-256color")], size, None, fd, Duration::from_millis(8)).expect("spawn"),
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
    fn wakeups_coalesce_into_one_byte_per_drain() {
        let (session, read) = session(&["/bin/sh", "-c", "for i in $(seq 200); do printf 'line %s\\n' $i; done; sleep 5"]);
        std::thread::sleep(Duration::from_millis(300));

        let mut buf = [0u8; 256];
        let n = nix::unistd::read(read.as_fd(), &mut buf).expect("read");
        assert_eq!(n, 1, "200 lines of output must not produce 200 wakeups");
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
        )
        .expect("spawn");

        let update = wait_for(&session, |u| rendered(u).contains("checked"));
        let text = rendered(&update);
        assert!(!text.contains("WAKE-LEAKED"), "the wake pipe reached the child:\n{text}");
        assert!(!text.contains("PTMX-LEAKED"), "the pty master reached the child:\n{text}");
        drop(read.0);
    }

    #[test]
    fn shutdown_is_idempotent_and_kills_the_child() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 300"]);
        let pid = session.pid().get();
        assert!(session.shutdown(), "the first call should be the one that tears down");
        assert!(!session.shutdown(), "a second call must be a no-op");
        assert!(!session.alive());
        assert_eq!(alive(pid), Err(Errno::ESRCH), "the child outlived an explicit shutdown");
    }

    #[test]
    fn shutdown_survives_a_child_that_ignores_sighup() {
        let (session, _read) = session(&["/bin/sh", "-c", "trap '' HUP; sleep 300"]);
        let pid = session.pid().get();
        std::thread::sleep(Duration::from_millis(150));
        assert!(session.shutdown());
        assert_eq!(alive(pid), Err(Errno::ESRCH), "SIGHUP alone is not enough here");
    }

    #[test]
    fn shutdown_returns_promptly() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 300"]);
        let start = Instant::now();
        session.shutdown();
        // Without the quit pipe this waits out the reader's poll timeout every time.
        assert!(start.elapsed() < Duration::from_millis(150), "took {:?}", start.elapsed());
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
        let (session, _read) = session(&["/bin/sh", "-c", r"printf '\033]133;A\007$ \033]133;B\007'"]);
        let update = wait_for(&session, |u| u.delta.events.contains(&Event::PromptStart));
        assert!(update.delta.events.contains(&Event::PromptEnd));
    }

    #[test]
    fn resize_reaches_the_child() {
        let (session, _read) = session(&["/bin/sh", "-c", "sleep 0.3; stty size"]);
        session.resize(Winsize { rows: 12, cols: 40 }).expect("resize");
        let update = wait_for(&session, |u| rendered(u).contains("12 40"));
        assert!(rendered(&update).contains("12 40"));
    }
}
