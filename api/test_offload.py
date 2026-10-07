"""`run_off_request` — the scorer must not wait on Apple.

A posted score was blocking on ~11 sequential HTTP/2 calls (up to 28 when the
start-push cooldown lapsed) before being acknowledged. On a course with poor
reception that lengthens the window in which the phone has to hold the
connection open, which is how a post fails on the 14th.
"""
import threading
import time

from django.test import TestCase, override_settings

from services.offload import run_off_request, enabled


@override_settings(TESTING=False)
class OffloadTests(TestCase):
    """`enabled()` is False under test so every OTHER test sees ordered,
    deterministic behaviour. These four are the pool's own tests, so they turn
    it back on explicitly."""

    def test_the_caller_returns_before_the_work_finishes(self):
        """The whole point: a slow task must not hold the request."""
        started  = threading.Event()
        release  = threading.Event()
        finished = threading.Event()

        def slow():
            started.set()
            release.wait(timeout=5)
            finished.set()

        t0 = time.perf_counter()
        handed = run_off_request(slow, label='test')
        elapsed = time.perf_counter() - t0

        self.assertTrue(handed, 'expected a hand-off')
        self.assertLess(elapsed, 0.2,
                        f'caller blocked for {elapsed:.2f}s — the point is '
                        f'that it does not')
        self.assertTrue(started.wait(timeout=5), 'the task must still run')
        self.assertFalse(finished.is_set(), 'it should still be in flight')
        release.set()
        self.assertTrue(finished.wait(timeout=5))

    def test_a_failing_task_never_reaches_the_caller(self):
        """The caller is a scoring request — a dead board must not take a
        posted score down with it."""
        ran = threading.Event()

        def boom():
            ran.set()
            raise RuntimeError('APNs exploded')

        with self.assertLogs('services.offload', level='ERROR') as logs:
            run_off_request(boom, label='boom')
            self.assertTrue(ran.wait(timeout=5))
            # Give the pool a moment to log before the context exits.
            for _ in range(50):
                if any('background task failed' in m for m in logs.output):
                    break
                time.sleep(0.02)
        self.assertTrue(any('background task failed' in m
                            for m in logs.output), logs.output)

    def test_the_env_switch_puts_it_back_inline(self):
        """`BACKGROUND_PUSH=0` must restore the old behaviour without a
        deploy — the rollback for an event day."""
        import os
        marker = []
        old = os.environ.get('BACKGROUND_PUSH')
        os.environ['BACKGROUND_PUSH'] = '0'
        try:
            self.assertFalse(enabled())
            handed = run_off_request(lambda: marker.append(1), label='inline')
            self.assertFalse(handed, 'should not hand off when disabled')
            self.assertEqual(marker, [1],
                             'and must have run INLINE, not been dropped')
        finally:
            if old is None:
                os.environ.pop('BACKGROUND_PUSH', None)
            else:
                os.environ['BACKGROUND_PUSH'] = old

    def test_it_is_on_by_default(self):
        import os
        old = os.environ.pop('BACKGROUND_PUSH', None)
        try:
            self.assertTrue(enabled())
        finally:
            if old is not None:
                os.environ['BACKGROUND_PUSH'] = old

    @override_settings(TESTING=True)
    def test_it_is_off_under_test(self):
        """Guards the guard: if this ever returns True, every push-related
        test in the suite becomes a race."""
        self.assertFalse(enabled())


class OffloadConnectionTests(TestCase):
    """The inline path must not close the caller's database connection.

    `BACKGROUND_PUSH=0` is the rollback switch — the thing to reach for mid
    event. An unconditional `connection.close()` made it the most dangerous
    setting in the file: the push ran in the request thread and then shut the
    connection the request was still using, taking the posted score down with
    the board. Caught by `NeverBreaksScoringTests`, which exists for exactly
    that failure.
    """

    @override_settings(TESTING=True)   # forces the inline path
    def test_running_inline_leaves_the_connection_open(self):
        from django.db import connection
        from scoring.tests._helpers import make_tee
        make_tee()                       # ensure a live connection
        self.assertIsNotNone(connection.connection)
        run_off_request(lambda: None, label='inline')
        self.assertIsNotNone(
            connection.connection,
            'the inline path closed the caller\'s connection — a posted '
            'score would die with the push',
        )
        # And it is still usable, not merely non-None.
        make_tee()
