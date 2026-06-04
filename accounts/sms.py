"""
accounts/sms.py
---------------
Pluggable SMS delivery for OTP login (freemium design §12).

`send_sms(phone, body)` dispatches to the backend named by the `SMS_BACKEND`
setting.  Two backends ship today:

  * "console" (default) — logs the message instead of sending.  Used in dev,
    tests, and CI; read the code off the server log (or the `debug_code` field
    the request endpoint returns when DEBUG=True).
  * "twilio" — sends via Twilio's REST API using TWILIO_* settings.  A thin
    stub for now: it validates configuration and posts to Twilio if the
    `twilio` package is installed.  Going live on real SMS is just flipping
    SMS_BACKEND to "twilio" once an account, number, and 10DLC registration
    exist — no code change elsewhere.

Both raise SmsError on a hard delivery failure so the OTP service can surface a
clean message; the caller never sees a provider stack trace.
"""

import logging

from django.conf import settings

logger = logging.getLogger(__name__)


class SmsError(Exception):
    """Raised when an SMS could not be delivered."""


def _console_send(phone: str, body: str) -> None:
    logger.info("[SMS] to=%s body=%s", phone, body)


def _twilio_send(phone: str, body: str) -> None:
    sid   = getattr(settings, 'TWILIO_ACCOUNT_SID', '')
    token = getattr(settings, 'TWILIO_AUTH_TOKEN', '')
    sender = getattr(settings, 'TWILIO_FROM', '')
    if not (sid and token and sender):
        raise SmsError(
            "Twilio SMS backend is selected but TWILIO_ACCOUNT_SID / "
            "TWILIO_AUTH_TOKEN / TWILIO_FROM are not configured."
        )
    try:
        from twilio.rest import Client  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on optional dep
        raise SmsError("The 'twilio' package is not installed.") from exc
    try:  # pragma: no cover - exercised only with real credentials
        Client(sid, token).messages.create(to=phone, from_=sender, body=body)
    except Exception as exc:  # pragma: no cover
        raise SmsError(f"Twilio delivery failed: {exc}") from exc


_BACKENDS = {
    'console': _console_send,
    'twilio':  _twilio_send,
}


def send_sms(phone: str, body: str) -> None:
    name = getattr(settings, 'SMS_BACKEND', 'console')
    backend = _BACKENDS.get(name)
    if backend is None:
        raise SmsError(f"Unknown SMS_BACKEND: {name!r}")
    backend(phone, body)
