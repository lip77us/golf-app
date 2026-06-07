"""
services/push.py
----------------
Push-notification delivery + recipient resolution for event-driven, in-app
notifications (round started, skin won, …) and, later, user-originated round
chat. Delivery is pluggable via the `PUSH_BACKEND` setting, mirroring
`SMS_BACKEND`:

  * `console` (default / dev) — logs the payload, sends nothing.
  * `fcm`                     — Firebase Cloud Messaging HTTP v1 (APNs for iOS,
                                FCM for Android). Requires FCM_* env / service
                                account; see docs/push-notifications.md.

Nothing here ever raises into the caller — a push failure must never block
scoring. Going live = flip `PUSH_BACKEND=fcm` + creds; no code change.
"""
import logging
import os

from django.conf import settings

logger = logging.getLogger(__name__)


# Per-category defaults. A user's notification_prefs override these by key; a
# missing key falls back to the default here.
NOTIFICATION_CATEGORIES = {
    'round_start':    True,
    'skins':          True,
    'round_complete': True,
    'lead_change':    True,   # Phase 2
    'chat':           True,   # Phase 3 (trash talk)
}


def category_enabled(user, category) -> bool:
    """True if `user` wants pushes for `category` (default per-category)."""
    prefs = getattr(user, 'notification_prefs', None) or {}
    return bool(prefs.get(category, NOTIFICATION_CATEGORIES.get(category, True)))


# --------------------------------------------------------------------------
# Delivery
# --------------------------------------------------------------------------

def send_push(tokens, title, body, data=None):
    """Deliver one notification to a list of device tokens. Returns the set of
    tokens FCM reported as unregistered (so callers can prune them). Never
    raises."""
    tokens = [t for t in (tokens or []) if t]
    if not tokens:
        return set()
    backend = getattr(settings, 'PUSH_BACKEND', 'console')
    try:
        if backend == 'fcm':
            return _send_fcm(tokens, title, body, data or {})
        return _send_console(tokens, title, body, data or {})
    except Exception:  # pragma: no cover - defensive; never break scoring
        logger.exception('push: send failed (%s)', backend)
        return set()


def _send_console(tokens, title, body, data):
    logger.info('[push:console] → %d device(s): %r / %r %r',
                len(tokens), title, body, data)
    return set()


_FCM_APP = None


def _fcm_app():  # pragma: no cover - needs creds
    """Lazily init the firebase-admin app from FCM_SERVICE_ACCOUNT_JSON (the
    Railway secret). Returns None when creds aren't configured."""
    global _FCM_APP
    if _FCM_APP is not None:
        return _FCM_APP
    raw = os.environ.get('FCM_SERVICE_ACCOUNT_JSON')
    if not raw:
        return None
    import json
    import firebase_admin
    from firebase_admin import credentials
    _FCM_APP = firebase_admin.initialize_app(
        credentials.Certificate(json.loads(raw)), name='halved-push')
    return _FCM_APP


def _send_fcm(tokens, title, body, data):  # pragma: no cover - needs creds
    """FCM HTTP v1 multicast send. Returns the tokens FCM reports as no longer
    registered (so callers prune them)."""
    app = _fcm_app()
    if app is None:
        logger.error('push: PUSH_BACKEND=fcm but FCM_SERVICE_ACCOUNT_JSON unset')
        return set()
    from firebase_admin import messaging
    toks = list(tokens)
    msg = messaging.MulticastMessage(
        tokens=toks,
        notification=messaging.Notification(title=title, body=body),
        data={k: str(v) for k, v in (data or {}).items()},
    )
    resp = messaging.send_each_for_multicast(msg, app=app)
    dead = set()
    for i, r in enumerate(resp.responses):
        if not r.success:
            exc = r.exception
            if isinstance(exc, getattr(messaging, 'UnregisteredError', ())) \
                    or 'unregistered' in str(getattr(exc, 'code', '')).lower():
                dead.add(toks[i])
    return dead


# --------------------------------------------------------------------------
# Recipients + high-level helpers
# --------------------------------------------------------------------------

def tokens_for_users(users, category):
    """Active device tokens for `users` who have `category` enabled."""
    from accounts.models import DeviceToken
    wanted = [u for u in users if category_enabled(u, category)]
    if not wanted:
        return []
    return list(
        DeviceToken.objects.filter(user__in=wanted)
        .values_list('token', flat=True))


def users_for_round(round_obj, *, include_watchers=True, exclude_user_ids=()):
    """Registered users following `round_obj` — participants (players matched by
    verified phone) plus, optionally, invited watchers."""
    from accounts.phone import normalize
    from django.contrib.auth import get_user_model
    from tournament.models import Watcher

    phones = set()
    for fs in round_obj.foursomes.all():
        for m in fs.memberships.all():
            if not m.player.is_phantom and m.player.phone:
                n = normalize(m.player.phone)
                if n:
                    phones.add(n)
    if include_watchers:
        q = {'round_id': round_obj.id}
        for w in Watcher.objects.filter(**q):
            phones.add(w.phone)
        if round_obj.tournament_id:
            for w in Watcher.objects.filter(tournament_id=round_obj.tournament_id):
                phones.add(w.phone)
    if not phones:
        return []
    qs = get_user_model().objects.filter(phone__in=phones)
    return [u for u in qs if u.id not in set(exclude_user_ids)]


def notify_round_event(round_obj, *, category, dedup_key, title, body,
                       data=None, include_watchers=True, exclude_user_ids=()):
    """Send an event push to a round's followers exactly once (idempotent via
    SentNotification). Returns True if it sent (first time), False if it was a
    duplicate / had no recipients. Prunes any tokens FCM rejects."""
    from accounts.models import DeviceToken, SentNotification

    _, created = SentNotification.objects.get_or_create(
        dedup_key=dedup_key, defaults={'event_type': category})
    if not created:
        return False  # already sent for this exact event

    users = users_for_round(
        round_obj, include_watchers=include_watchers,
        exclude_user_ids=exclude_user_ids)
    tokens = tokens_for_users(users, category)
    if not tokens:
        return False
    payload = {'type': category, 'round_id': str(round_obj.id)}
    if data:
        payload.update(data)
    dead = send_push(tokens, title, body, payload)
    if dead:
        DeviceToken.objects.filter(token__in=dead).delete()
    return True


# --------------------------------------------------------------------------
# Event hooks (Phase 1 — basic: round started / completed)
# --------------------------------------------------------------------------

def _is_multi_group(round_obj):
    """Notify only for multi-group rounds: multi-foursome tournaments and
    multi-group skins. Single-foursome casual rounds get nothing."""
    return (round_obj.tournament_id is not None
            or round_obj.foursomes.count() > 1)


def maybe_notify_round_started(round_obj):
    """Round-start push for multi-group rounds. Best-effort; never raises (a
    notification problem must not break starting a round)."""
    try:
        if not _is_multi_group(round_obj):
            return
        notify_round_event(
            round_obj, category='round_start',
            dedup_key=f'round_start:round={round_obj.id}',
            title='Round under way',
            body=f'Your round at {round_obj.course.name} has started.')
    except Exception:  # pragma: no cover - defensive
        logger.exception('push: round_started failed (round %s)', round_obj.id)


def maybe_notify_round_complete(round_obj):
    """Round-complete push for multi-group rounds. Best-effort; never raises."""
    try:
        if not _is_multi_group(round_obj):
            return
        notify_round_event(
            round_obj, category='round_complete',
            dedup_key=f'round_complete:round={round_obj.id}',
            title='Round complete',
            body=f'Final results are in for {round_obj.course.name}.')
    except Exception:  # pragma: no cover - defensive
        logger.exception('push: round_complete failed (round %s)', round_obj.id)
