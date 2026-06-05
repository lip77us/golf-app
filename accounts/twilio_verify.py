"""
accounts/twilio_verify.py
-------------------------
Twilio Verify backend for phone-OTP login.

When OTP_BACKEND == 'twilio_verify', Twilio (not our PhoneOTP table) owns the
code: it generates, delivers, rate-limits, and checks it.  We only kick off a
verification and later ask Twilio whether a submitted code is approved.  This
offloads code storage and most carrier-compliance burden — a good fit for a
one-time-per-user login (see CLAUDE.md "Live SMS").

Config (env on Railway): TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN,
TWILIO_VERIFY_SERVICE_SID.  The `twilio` package must be installed
(requirements.txt); it's imported lazily so the default 'local' backend never
needs it.

`start_verification` / `check_verification` raise TwilioVerifyError on a hard
failure (misconfig, network/API error); the OTP service maps that to a clean
user-facing message.  A wrong/expired code is NOT an error — `check_verification`
returns False.
"""

from django.conf import settings


class TwilioVerifyError(Exception):
    """Hard failure talking to Twilio Verify (config/network/API)."""


def _client_and_service():
    sid     = getattr(settings, 'TWILIO_ACCOUNT_SID', '')
    token   = getattr(settings, 'TWILIO_AUTH_TOKEN', '')
    service = getattr(settings, 'TWILIO_VERIFY_SERVICE_SID', '')
    if not (sid and token and service):
        raise TwilioVerifyError(
            "Twilio Verify is selected but TWILIO_ACCOUNT_SID / "
            "TWILIO_AUTH_TOKEN / TWILIO_VERIFY_SERVICE_SID are not configured."
        )
    try:
        from twilio.rest import Client  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on optional dep
        raise TwilioVerifyError("The 'twilio' package is not installed.") from exc
    return Client(sid, token), service


def start_verification(phone: str) -> None:
    """Ask Twilio to send an SMS code to `phone` (E.164)."""
    client, service = _client_and_service()
    try:  # pragma: no cover - exercised only with real credentials
        client.verify.v2.services(service).verifications.create(
            to=phone, channel='sms',
        )
    except Exception as exc:  # pragma: no cover
        raise TwilioVerifyError(f"Twilio Verify send failed: {exc}") from exc


def check_verification(phone: str, code: str) -> bool:
    """
    Return True iff Twilio reports `code` as approved for `phone`.

    A missing/expired verification (Twilio 404) or a non-approved status returns
    False; only genuine transport/config failures raise.
    """
    client, service = _client_and_service()
    try:  # pragma: no cover - exercised only with real credentials
        from twilio.base.exceptions import TwilioRestException  # type: ignore
        try:
            result = client.verify.v2.services(service).verification_checks.create(
                to=phone, code=code,
            )
        except TwilioRestException as exc:
            if getattr(exc, 'status', None) == 404:
                return False  # no pending verification (expired / already used)
            raise TwilioVerifyError(f"Twilio Verify check failed: {exc}") from exc
    except TwilioVerifyError:
        raise
    except Exception as exc:  # pragma: no cover
        raise TwilioVerifyError(f"Twilio Verify check failed: {exc}") from exc
    return getattr(result, 'status', None) == 'approved'
