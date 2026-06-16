"""
accounts/otp.py
---------------
Phone-OTP login service (freemium design §12).

Two entry points used by the API views:

  * request_code(phone)         -> (normalized_phone, plaintext_code | None)
        Normalizes and sends a login code.  Returns the plaintext on the LOCAL
        backend (so the view can echo it as `debug_code` under DEBUG; never in
        prod) and None on the Twilio Verify backend (Twilio owns the code).

  * verify_code(phone, code, name=None) -> (user, is_new_account)
        Validates the code, then resolves the phone to a user:
          - known phone   -> log that user in (stamp phone_verified_at)
          - unknown phone -> SELF-CREATE Account + admin User + linked Player
                             and flag is_new_account=True.

Two pluggable backends, chosen by the OTP_BACKEND setting:
  - 'local'         (default): our PhoneOTP table (hashed codes, TTL, attempts)
                    + pluggable SMS delivery (SMS_BACKEND).  Console in dev.
  - 'twilio_verify' (prod):    Twilio Verify generates/sends/checks the code
                    (accounts/twilio_verify.py).  See docs/twilio-verify-setup.md.

All user-facing failure modes raise OtpError(message); the view maps that to a
400 with the message.  The password-login path (LoginView / AccountBackend) is
untouched — this is an additive, parallel identity path.
"""

from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone

from .models import Account, PhoneOTP
from .phone import normalize
from .sms import send_sms, SmsError

# Anti-abuse: cap how many codes a single number can request per window so a
# hostile client can't run up SMS cost or spam a victim's phone.
OTP_REQUESTS_PER_HOUR = 5


class OtpError(Exception):
    """User-facing OTP failure; carries a message safe to show the client."""


def _use_twilio_verify() -> bool:
    """
    True when Twilio Verify owns code generation/delivery/checking
    (OTP_BACKEND='twilio_verify').  Default 'local' keeps our PhoneOTP table +
    the SMS_BACKEND delivery path — so nothing changes until the env var is set.
    """
    return getattr(settings, 'OTP_BACKEND', 'local') == 'twilio_verify'


def _review_bypass_phones() -> set[str]:
    """Normalized reviewer demo-phone(s) that skip real OTP, or empty when the
    bypass isn't configured (BOTH REVIEW_BYPASS_PHONE and _CODE must be set).
    REVIEW_BYPASS_PHONE may be a comma-separated list — e.g. the reviewer login
    number plus a deletable account for Apple's account-deletion check. Lets the
    reviewer sign in via the phone screen without an SMS; each number must
    already map to a seeded User (seed_demo's reviewer / reviewer_delete)."""
    raw  = (getattr(settings, 'REVIEW_BYPASS_PHONE', '') or '').strip()
    code = (getattr(settings, 'REVIEW_BYPASS_CODE', '') or '').strip()
    if not raw or not code:
        return set()
    return {n for n in (normalize(p.strip()) for p in raw.split(',')) if n}


def _is_review_bypass(phone: str, code: str) -> bool:
    """True when (phone, code) match the configured reviewer demo bypass."""
    if phone not in _review_bypass_phones():
        return False
    return code == (getattr(settings, 'REVIEW_BYPASS_CODE', '') or '').strip()


def request_code(raw_phone: str) -> tuple[str, str | None]:
    """
    Send a login code to `raw_phone`.  Returns (normalized_phone, code) where
    `code` is the plaintext for DEBUG echo on the LOCAL backend, and None on the
    Twilio Verify backend (Twilio owns the code, so there's nothing to echo).
    """
    phone = normalize(raw_phone)
    if not phone:
        raise OtpError("Enter a valid phone number.")

    # Reviewer demo-phone: skip real OTP delivery (Apple can't receive an SMS).
    # The fixed code is accepted in verify_code; nothing is sent here.
    if phone in _review_bypass_phones():
        return phone, None

    if _use_twilio_verify():
        from . import twilio_verify
        try:
            twilio_verify.start_verification(phone)
        except twilio_verify.TwilioVerifyError as exc:
            raise OtpError("Could not send the code. Please try again.") from exc
        return phone, None

    # Local backend: our PhoneOTP table + pluggable SMS delivery.  (Twilio
    # Verify enforces its own per-number rate limits, so the counter below is
    # only needed here.)
    window_start = timezone.now() - timedelta(hours=1)
    recent = PhoneOTP.objects.filter(phone=phone, created_at__gte=window_start).count()
    if recent >= OTP_REQUESTS_PER_HOUR:
        raise OtpError("Too many code requests. Please try again later.")

    code = PhoneOTP.issue(phone)
    try:
        send_sms(phone, f"Your Halved code is {code}. It expires in 10 minutes.")
    except SmsError as exc:
        raise OtpError("Could not send the code. Please try again.") from exc
    return phone, code


def verify_code(raw_phone: str, code: str, name: str | None = None):
    phone = normalize(raw_phone)
    if not phone:
        raise OtpError("Enter a valid phone number.")

    code = (code or '').strip()
    if not code:
        raise OtpError("That code is invalid or expired.")

    if _is_review_bypass(phone, code):
        pass  # reviewer demo-phone — approved without contacting Twilio/PhoneOTP
    elif _use_twilio_verify():
        from . import twilio_verify
        try:
            approved = twilio_verify.check_verification(phone, code)
        except twilio_verify.TwilioVerifyError as exc:
            raise OtpError("Could not verify the code. Please try again.") from exc
        if not approved:
            raise OtpError("That code is invalid or expired.")
    else:
        if not PhoneOTP.check_code(phone, code):
            raise OtpError("That code is invalid or expired.")

    User = get_user_model()
    user = User.objects.filter(phone=phone).first()
    if user is not None:
        if user.phone_verified_at is None:
            user.phone_verified_at = timezone.now()
            user.save(update_fields=['phone_verified_at'])
        return user, False

    return _create_account_for_phone(phone, name), True


def _unique_account_name(base: str) -> str:
    """A case-insensitively-unique Account.name derived from `base`."""
    candidate = base
    n = 2
    while Account.objects.filter(name__iexact=candidate).exists():
        candidate = f"{base} {n}"
        n += 1
    return candidate


@transaction.atomic
def _create_account_for_phone(phone: str, name: str | None):
    # Imported lazily to avoid an app-loading cycle (core depends on accounts).
    from core.models import Player

    User = get_user_model()
    display = (name or '').strip()

    base_name = f"{display}'s Golf" if display else f"Golf {phone[-4:]}"
    account = Account.objects.create(name=_unique_account_name(base_name))

    # The account is brand new, so any username is unique within it; the phone
    # is a guaranteed-distinct, validator-safe value (digits + leading '+').
    user = User.objects.create_user(
        username=phone,
        account=account,
        is_account_admin=True,
    )
    user.set_unusable_password()  # phone/OTP is the only credential
    user.phone = phone
    user.phone_verified_at = timezone.now()
    user.save()

    Player.objects.create(
        account=account,
        user=user,
        name=display or 'New Golfer',
        phone=phone,
        handicap_index=Decimal('0.0'),
    )
    return user
