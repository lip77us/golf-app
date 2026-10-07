"""
services/offload.py
-------------------
Run slow, non-essential work off the request thread.

Built for the lock-screen push. A posted score was blocking on roughly eleven
sequential HTTP/2 calls to Apple and Google — up to twenty-eight when the
15-minute start-push cooldown lapsed — before the scorer got his
acknowledgement. Those calls are fast from Railway, but they lengthen the
window in which a phone on poor course reception has to hold the connection
open, which is how a post times out on the 14th fairway.

**`transaction.on_commit` is not backgrounding.** It defers past the commit
and then runs in the same thread, inside the same request. The deferral is
right and stays — nothing should announce a board built from scores that
might still roll back — but it buys no latency.

Deliberate choices
~~~~~~~~~~~~~~~~~~
* **A bounded pool, not a thread per call.** Scores can arrive in bursts from
  a dozen groups; spawning a thread each time would be unbounded. Two workers
  is plenty for work nobody is waiting on, and a full queue is a sign the
  pushes are hanging rather than a reason to add threads.
* **The connection is CLOSED after each task.** Django opens a fresh
  connection per thread, and a pooled thread outlives the request — without
  this they accumulate until Postgres refuses new ones.
* **A refused submission runs INLINE rather than being dropped.** A slow
  board beats a missing one, and the pool only refuses while shutting down.
* **One env switch.** `BACKGROUND_PUSH=0` puts everything back in the request
  thread without a deploy, so the change can be undone from Railway if it
  misbehaves during an event.
"""
import logging
import os
from concurrent.futures import ThreadPoolExecutor

logger = logging.getLogger(__name__)

_POOL = ThreadPoolExecutor(max_workers=2, thread_name_prefix='halved-bg')


def enabled() -> bool:
    """False puts the work back in the calling thread. Default on.

    Always off under test. A pool plus TestCase's wrapping transaction is
    nondeterministic — the worker cannot see uncommitted rows, and an
    assertion about whether the task ran becomes a race. The pool has its own
    tests; every other test should see the simple, ordered behaviour.
    """
    try:
        from django.conf import settings
        if getattr(settings, 'TESTING', False):
            return False
    except Exception:
        pass
    return (os.environ.get('BACKGROUND_PUSH', '1') or '').lower() \
        not in ('0', 'false', 'no', '')


def _guarded(fn, label: str, *, own_connection: bool) -> None:
    """Run *fn*, swallow anything it raises, and tidy up after it.

    `own_connection` says whether this call owns the database connection it
    is using. A POOL thread does: Django opens a fresh one per thread and a
    pooled thread outlives the request, so leaving it open leaks until
    Postgres refuses new ones.

    **Running INLINE does not.** There the connection belongs to the request
    that called us — closing it would shut the caller's connection mid-flight
    and take the posted score down with the board. Found by
    `NeverBreaksScoringTests`, which is exactly the failure it was written
    for; an unconditional close made `BACKGROUND_PUSH=0` — the rollback
    switch — the most dangerous setting in the file.
    """
    try:
        fn()
    except Exception:
        # Nobody is waiting on this, so a failure must never escape — but it
        # must be visible, or a silently dead board is indistinguishable from
        # a feature nobody turned on.
        logger.exception('background task failed: %s', label)
    finally:
        if own_connection:
            from django.db import connection
            connection.close()


def run_off_request(fn, *, label: str = '') -> bool:
    """Run *fn* on the pool. Returns True if it was handed off.

    Never raises: the caller is a scoring request.
    """
    if not enabled():
        _guarded(fn, label, own_connection=False)
        return False
    try:
        _POOL.submit(_guarded, fn, label, own_connection=True)
        return True
    except Exception:
        logger.exception('could not offload %s — running inline', label)
        _guarded(fn, label, own_connection=False)
        return False
