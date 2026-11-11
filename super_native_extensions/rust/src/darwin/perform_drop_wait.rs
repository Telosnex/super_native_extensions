//! The main-thread wait for the Dart `onPerformDrop` handler, shared by the
//! macOS and iOS drop contexts.

use std::{
    cell::Cell,
    time::{Duration, Instant},
};

use irondash_run_loop::{platform::PollSession, RunLoop};

/// How long the platform drop handler (`performDragOperation:` on macOS,
/// `dropInteraction:performDrop:` on iOS) waits for the Dart `onPerformDrop`
/// handler.
///
/// The wait blocks the main thread, and the drag session cannot end until
/// the platform handler returns. Some drag sources write promised files
/// only after the session ends (for example the macOS screenshot thumbnail).
/// A handler that awaits such a file would wait forever, so the wait is
/// limited. The handler keeps running after the timeout, and Dart disposes the
/// reader only after the handler completes.
pub(crate) const PERFORM_DROP_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PerformDropWait {
    Completed,
    TimedOut,
}

/// Runs the run loop until `done` is set or `timeout` elapses.
pub(crate) fn wait_for_perform_drop(done: &Cell<bool>, timeout: Duration) -> PerformDropWait {
    let deadline = Instant::now() + timeout;
    // poll_once can block for up to 1 s when there are no events. Wake it at
    // the deadline. A timer alone does not end poll_once (CFRunLoopRunInMode
    // returns after a source is handled, not after a timer fires), so the
    // timer signals the run loop source through a sender.
    let sender = RunLoop::current().new_sender();
    let _wake_at_deadline = RunLoop::current().schedule(timeout, move || sender.send(|| {}));
    let mut poll_session = PollSession::new();
    while !done.get() {
        if Instant::now() >= deadline {
            return PerformDropWait::TimedOut;
        }
        RunLoop::current()
            .platform_run_loop
            .poll_once(&mut poll_session);
    }
    PerformDropWait::Completed
}

#[cfg(test)]
mod tests {
    use std::{
        cell::Cell,
        sync::mpsc,
        thread,
        time::{Duration, Instant},
    };

    use irondash_run_loop::RunLoop;

    use super::{wait_for_perform_drop, PerformDropWait};

    /// Runs `f` on its own thread (with its own run loop). If `f` does not
    /// return within `limit`, the test fails instead of hanging.
    fn run_with_limit<T: Send + 'static>(
        limit: Duration,
        f: impl FnOnce() -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            tx.send(f()).ok();
        });
        rx.recv_timeout(limit)
            .expect("wait_for_perform_drop did not return; the platform thread would hang")
    }

    #[test]
    fn perform_drop_wait_returns_when_handler_completes() {
        thread_local! {
            static DONE: Cell<bool> = const { Cell::new(false) };
        }
        let (outcome, elapsed) = run_with_limit(Duration::from_secs(5), || {
            // The Dart reply comes from another thread through a sender, as
            // the message channel does.
            let sender = RunLoop::current().new_sender();
            thread::spawn(move || {
                thread::sleep(Duration::from_millis(50));
                sender.send(|| DONE.with(|done| done.set(true)));
            });
            let start = Instant::now();
            let outcome = DONE.with(|done| wait_for_perform_drop(done, Duration::from_secs(3)));
            (outcome, start.elapsed())
        });
        assert_eq!(outcome, PerformDropWait::Completed);
        assert!(elapsed < Duration::from_secs(1), "elapsed: {elapsed:?}");
    }

    #[test]
    fn perform_drop_wait_times_out_when_handler_never_completes() {
        // For example, the handler awaits a promised file that the drag source
        // only writes after the drag session ends.
        let (outcome, elapsed) = run_with_limit(Duration::from_secs(5), || {
            // A pending timer keeps the run loop non-empty, as on the main
            // thread. Without it, poll_once returns at once instead of blocking.
            let _keep_run_loop_busy = RunLoop::current().schedule(Duration::from_secs(60), || {});
            let done = Cell::new(false);
            let start = Instant::now();
            let outcome = wait_for_perform_drop(&done, Duration::from_millis(200));
            (outcome, start.elapsed())
        });
        assert_eq!(outcome, PerformDropWait::TimedOut);
        assert!(
            elapsed >= Duration::from_millis(200),
            "elapsed: {elapsed:?}"
        );
        // poll_once can block for up to 1 s. The wait must wake at the deadline.
        assert!(elapsed < Duration::from_millis(700), "elapsed: {elapsed:?}");
    }
}
