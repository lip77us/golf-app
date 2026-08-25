"""
services/live_activity_push.py
------------------------------
Delivery for the Sixes lock screen
(docs/design-review/handoff-sixes-lock/SPEC.md).

**This cannot go through FCM.**  A Live Activity update is its own APNs push
type — `apns-push-type: liveactivity`, addressed to a topic suffixed
`.push-type.liveactivity`, carrying a `content-state` rather than a
notification — and Firebase offers no way to set those.  So this is a direct
APNs client, and the only part of the notification stack that is.

Pluggable like `services.push`, and for the same reason:

  * `console` (default / dev) — logs what it would send, sends nothing.
  * `apns`                    — signs an ES256 provider token and posts over
                                HTTP/2.  Requires APNS_* env; see below.

Nothing here raises into the caller.  A lock screen that stops updating is a
lock screen that is merely stale; a scoring request that fails because of one
is a real problem.

Configuration
-------------
    LIVE_ACTIVITY_BACKEND   'console' | 'apns'
    APNS_KEY_ID             the 10-character Key ID of the .p8
    APNS_TEAM_ID            the 10-character Apple team id
    APNS_KEY_PATH           path to AuthKey_XXXXXXXXXX.p8  (use this locally —
                            the .env reader is line-based and cannot hold a
                            multi-line value)
    APNS_KEY_P8             the key's contents  (use this on Railway, whose
                            variables do hold newlines)
    APNS_BUNDLE_ID          defaults to us.lipkin.golfapp
    APNS_SANDBOX            '1' for builds installed by Xcode / `flutter run`.
                            TestFlight and the App Store are production.

The sandbox flag is the single most common reason a correct-looking push
vanishes: a development build's token is only valid against the sandbox host,
and the production host answers `BadDeviceToken` for it.
"""
import json
import logging
import os
import time

from django.conf import settings

logger = logging.getLogger(__name__)

_PROD_HOST    = 'https://api.push.apple.com'
_SANDBOX_HOST = 'https://api.sandbox.push.apple.com'

# Apple rejects a provider token older than an hour and refuses one minted more
# than once every 20 minutes, so it is cached and refreshed well inside both.
_TOKEN_TTL = 45 * 60

_jwt_cache = {'token': None, 'issued': 0.0}


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

def _backend() -> str:
    return getattr(settings, 'LIVE_ACTIVITY_BACKEND', None) \
        or os.environ.get('LIVE_ACTIVITY_BACKEND', 'console')


def _bundle_id() -> str:
    return os.environ.get('APNS_BUNDLE_ID', 'us.lipkin.golfapp')


def _host() -> str:
    return _SANDBOX_HOST if os.environ.get('APNS_SANDBOX') in ('1', 'true') \
        else _PROD_HOST


def _private_key() -> str | None:
    """The .p8 contents, from a path locally or the value itself on Railway."""
    path = os.environ.get('APNS_KEY_PATH')
    if path:
        try:
            with open(path) as fh:
                return fh.read()
        except OSError:
            logger.error('live_activity_push: cannot read APNS_KEY_PATH=%s',
                         path)
            return None
    return os.environ.get('APNS_KEY_P8') or None


def is_configured() -> bool:
    """True when a real send could succeed.  Checked by the management command
    so a misconfiguration reads as one line rather than a silent no-op."""
    return bool(_private_key()
                and os.environ.get('APNS_KEY_ID')
                and os.environ.get('APNS_TEAM_ID'))


# --------------------------------------------------------------------------
# Provider token
# --------------------------------------------------------------------------

def _provider_token():  # pragma: no cover - needs creds
    now = time.time()
    if _jwt_cache['token'] and now - _jwt_cache['issued'] < _TOKEN_TTL:
        return _jwt_cache['token']

    import jwt  # PyJWT[crypto]
    key = _private_key()
    if not key:
        return None
    token = jwt.encode(
        {'iss': os.environ['APNS_TEAM_ID'], 'iat': int(now)},
        key,
        algorithm='ES256',
        headers={'kid': os.environ['APNS_KEY_ID']},
    )
    _jwt_cache['token']  = token
    _jwt_cache['issued'] = now
    return token


# --------------------------------------------------------------------------
# Delivery
# --------------------------------------------------------------------------

def _apns_payload(state, *, event='update', dismiss_after=None) -> dict:
    """The `aps` envelope Apple expects for a Live Activity.

    `timestamp` is not decoration: iOS uses it to discard a push that arrives
    out of order, which on a golf course is routine rather than exotic.
    """
    aps = {
        'timestamp'     : int(time.time()),
        'event'         : event,
        'content-state' : state,
    }
    if event == 'end':
        # A few minutes on the lock screen after the round is signed, then it
        # takes itself away.
        aps['dismissal-date'] = int(time.time() + (dismiss_after or 5 * 60))
    return {'aps': aps}


def send_state(device_token: str, state: dict, *, event='update') -> bool:
    """Push one activity state to one token.  Returns True if Apple took it.

    Never raises: the caller is a scoring request.
    """
    backend = _backend()
    payload = _apns_payload(state, event=event)
    try:
        if backend == 'apns':
            return _send_apns(device_token, payload)
        return _send_console(device_token, payload)
    except Exception:  # pragma: no cover - defensive
        logger.exception('live_activity_push: send failed (%s)', backend)
        return False


def _send_console(device_token, payload) -> bool:
    logger.info('[live-activity:console] → %s…\n%s',
                device_token[:12], json.dumps(payload, indent=2))
    return True


def _headers(provider_token: str) -> dict:
    """Split out from the send so the two strings that silently break delivery
    are testable without an Apple key."""
    return {
        'authorization' : f'bearer {provider_token}',
        'apns-push-type': 'liveactivity',
        # The activity topic is the bundle id with this suffix.  The bare
        # bundle id is the APP's topic and Apple rejects it here — which is
        # the failure that looks exactly like a working push that never lands.
        'apns-topic'    : f'{_bundle_id()}.push-type.liveactivity',
        'apns-priority' : '10',
    }


_client = None


def _http():  # pragma: no cover - needs creds
    """One long-lived HTTP/2 client, reused across pushes.

    This matters more than it looks.  The sends happen inside the score-post
    request, one per golfer in the group, and a fresh client per send means a
    fresh TLS and HTTP/2 handshake per send — four of them, sequentially, in
    front of the golfer waiting for their score to save.  APNs is built to be
    held open and multiplexed, so holding one connection turns four handshakes
    into four frames on a socket that is already warm.
    """
    global _client
    if _client is None:
        import httpx  # httpx[http2] — APNs is HTTP/2 only
        _client = httpx.Client(
            http2=True,
            timeout=httpx.Timeout(5.0, connect=3.0),
            limits=httpx.Limits(max_keepalive_connections=4),
        )
    return _client


def _send_apns(device_token, payload) -> bool:  # pragma: no cover - needs creds
    token = _provider_token()
    if token is None:
        logger.error('live_activity_push: LIVE_ACTIVITY_BACKEND=apns but no '
                     'APNS key configured')
        return False

    resp = _http().post(f'{_host()}/3/device/{device_token}',
                        headers=_headers(token),
                        content=json.dumps(payload))
    if resp.status_code == 200:
        return True
    logger.error('live_activity_push: APNs %s for %s… — %s',
                 resp.status_code, device_token[:12], resp.text)
    return False


# --------------------------------------------------------------------------
# The round-level entry point
# --------------------------------------------------------------------------

def push_round(round_obj, *, final=False) -> int:
    """Send the current board to every activity registered for this round.

    Built per recipient, because the money line is the one slot that differs
    between the four golfers — everything else is the same string on all four
    phones, which is the whole design.

    Returns the number Apple accepted.
    """
    from api.views import _holes_played, _sixes_foursome_for
    from services.live_activity import sixes_activity_state, sixes_final_state
    from tournament.models import LiveActivityToken

    rows = list(LiveActivityToken.objects.filter(round=round_obj)
                .select_related('user'))
    if not rows:
        return 0

    sent = 0
    for row in rows:
        try:
            foursome, player_id = _sixes_foursome_for(round_obj, row.user)
            if foursome is None:
                continue
            if final:
                state = sixes_final_state(foursome, player_id=player_id)
            else:
                state = sixes_activity_state(
                    foursome, player_id=player_id,
                    thru=_holes_played(foursome))
            if not state:
                continue
            if send_state(row.token, state,
                          event='end' if final else 'update'):
                sent += 1
        except Exception:  # pragma: no cover - one bad row never stops the rest
            logger.exception('live_activity_push: round %s user %s',
                             round_obj.id, row.user_id)

    if final:
        # The activity is over; a token that can no longer be delivered to is
        # only a way to waste the next request.
        LiveActivityToken.objects.filter(round=round_obj).delete()
    return sent
