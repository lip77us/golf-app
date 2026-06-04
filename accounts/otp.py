"""
accounts/otp.py
---------------
Phone-OTP login service (freemium design §12).

Two entry points used by the API views:

  * request_code(phone)         -> (normalized_phone, plaintext_code)
        Normalizes, rate-limits, mints an OTP, and sends it via the SMS
        backend.  The plaintext is returned so the view can echo it as
        `debug_code` under DEBUG; never expose it in production responses.

  * verify_code(phone, code, name=None) -> (user, is_new_account)
        Validates the code, then resolves the phone to a user:
          - known phone   -> log that user in (stamp phone_verified_at)
          - unknown phone -> SELF-CREATE Account + admin User + linked Player
                             and flag is_new_account=True.

All user-facing failure modes raise OtpError(message); the view maps that to a
400 with the message.  The password-login path (LoginView / AccountBackend) is
untouched — this is an additive, parallel identity path.
"""

from datetime import timedelta
from decimal import Decimal

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


def request_code(raw_phone: str) -> tuple[str, str]:
    phone = normalize(raw_phone)
    if not phone:
        raise OtpError("Enter a valid phone number.")

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
    if not code or not PhoneOTP.check_code(phone, code.strip()):
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
