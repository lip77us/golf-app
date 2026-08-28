"""
console/auth.py
---------------
Web sign-in for the TD console.

**The console adds no identity concept.**  A TD is a golfer with events, so the
credential is the one they already have: a phone number, then a 6-digit SMS
code, issued and checked by ``accounts/otp.py`` — the same path the app uses.
The only thing web adds is a session cookie where the app holds a token.

Two deliberate differences from the app's OTP view:

* **No account is created on the web.**  ``otp.verify_code`` self-creates an
  Account for an unrecognised number; sign-up needs a name, an index and a
  phone in hand, so the console checks the number is known *before* sending
  anything.  An unknown number is a dead end that points back at the app —
  and it costs no SMS to say so.

* **Wrong codes count down out loud.**  "Two tries left" is worth more than
  "invalid code", so attempts are tracked per pending number and the resend
  link goes live the moment the first attempt fails.
"""

from __future__ import annotations

import functools
import time

from django.contrib.auth import get_user_model, login as django_login
from django.shortcuts import redirect
from django.urls import reverse

from accounts.phone import normalize


# Session keys.  All namespaced so the console can never collide with a session
# the API or the admin put there.
PENDING_PHONE   = 'td_pending_phone'      # normalized E.164 awaiting a code
PENDING_TYPED   = 'td_pending_typed'      # as the TD typed it, for the back link
CODE_SENT_AT    = 'td_code_sent_at'       # epoch seconds, drives the resend countdown
CODE_ATTEMPTS   = 'td_code_attempts'      # wrong codes so far for this number
RETURN_TO       = 'td_return_to'          # path a lapsed session was thrown off
RETURN_LABEL    = 'td_return_label'       # ...and what that screen is called

# Three tries, then the code is spent and a fresh one has to be sent.  Twilio
# Verify enforces its own attempt cap server-side; this is the number we can
# actually count down for the TD.
MAX_ATTEMPTS = 3
# Seconds before Resend goes live on its own.  A failed attempt unlocks it
# immediately — at that point the likeliest problem is the wrong phone.
RESEND_AFTER = 30

# 30 days.  A TD uses the same laptop every time, so `Keep me signed in` is on
# by default; unchecked falls back to a browser-session cookie.
REMEMBER_SECONDS = 30 * 24 * 60 * 60


class SignInError(Exception):
    """A sign-in failure with a message safe to put on the page."""


def phone_is_known(raw_phone: str) -> bool:
    """True when this number already belongs to a Halved user.

    Checked before a code is sent, not after it is verified: the console must
    not create accounts, and telling someone "create your account in the app
    first" is a better answer than an SMS followed by the same sentence.
    """
    phone = normalize(raw_phone)
    if not phone:
        return False
    return get_user_model().objects.filter(phone=phone).exists()


def start(request, raw_phone: str) -> None:
    """Send a code and park the pending number on the session.

    Raises ``SignInError`` for an unusable number, an unknown number, or a
    delivery/rate-limit failure — the message is the one shown on the page.
    """
    from accounts import otp as otp_service

    phone = normalize(raw_phone)
    if not phone:
        raise SignInError('Enter a valid mobile number.')
    if not phone_is_known(phone):
        raise SignInError(
            'We don’t have that number. Create your account in the Halved app '
            'first — the console shows the events you already run.')
    try:
        otp_service.request_code(phone)
    except otp_service.OtpError as exc:
        # Covers the per-number hourly cap as well as a delivery failure; the
        # service already words both for a person.
        raise SignInError(str(exc)) from exc

    request.session[PENDING_PHONE] = phone
    request.session[PENDING_TYPED] = raw_phone.strip()
    request.session[CODE_SENT_AT]  = int(time.time())
    request.session[CODE_ATTEMPTS] = 0


def resend(request) -> None:
    """Send a fresh code to the number already pending.  Resets the counter —
    a new code deserves a full set of tries."""
    phone = request.session.get(PENDING_PHONE)
    if not phone:
        raise SignInError('Start again — we lost track of that number.')
    start(request, phone)


def attempts_left(request) -> int:
    return max(0, MAX_ATTEMPTS - int(request.session.get(CODE_ATTEMPTS, 0)))


def resend_wait(request) -> int:
    """Seconds until Resend goes live.  Zero once a code has failed once —
    a wrong code usually means the SMS went to the wrong phone, and making
    someone wait 30 seconds to find that out is the wrong trade."""
    if request.session.get(CODE_ATTEMPTS, 0) > 0:
        return 0
    sent = request.session.get(CODE_SENT_AT)
    if not sent:
        return 0
    return max(0, RESEND_AFTER - (int(time.time()) - int(sent)))


def finish(request, code: str, *, remember: bool):
    """Check the code and open a web session.  Returns the signed-in user.

    Raises ``SignInError`` on a wrong code, with the tries left counted in the
    message.  Running out clears the pending code so the next step is a resend
    rather than a fourth guess at a spent one.
    """
    from accounts import otp as otp_service

    phone = request.session.get(PENDING_PHONE)
    if not phone:
        raise SignInError('That code has expired. Enter your number again.')

    try:
        user, is_new = otp_service.verify_code(phone, code)
    except otp_service.OtpError:
        used = int(request.session.get(CODE_ATTEMPTS, 0)) + 1
        request.session[CODE_ATTEMPTS] = used
        left = MAX_ATTEMPTS - used
        if left <= 0:
            request.session[CODE_ATTEMPTS] = 0
            request.session[CODE_SENT_AT] = 0
            raise SignInError(
                'That code doesn’t match, and it’s now spent. '
                'Send a new one and try again.')
        tries = 'One try' if left == 1 else f'{_word(left)} tries'
        raise SignInError(
            f'That code doesn’t match. {tries} left, then we’ll send a new one.')

    if is_new:
        # phone_is_known() gates start(), so this should be unreachable — but
        # an account materialising on the web is exactly the thing this flow
        # promises never to do, so it fails loudly rather than quietly.
        raise SignInError(
            'That number isn’t set up yet. Create your account in the Halved '
            'app first.')

    # AUTHENTICATION_BACKENDS holds only AccountBackend and we did not go
    # through authenticate(), so login() needs the backend named explicitly.
    django_login(request, user, backend='accounts.backends.AccountBackend')
    request.session.set_expiry(REMEMBER_SECONDS if remember else 0)

    for key in (PENDING_PHONE, PENDING_TYPED, CODE_SENT_AT, CODE_ATTEMPTS):
        request.session.pop(key, None)
    return user


def _word(n: int) -> str:
    return {2: 'Two', 3: 'Three'}.get(n, str(n))


def take_return_to(request) -> tuple[str, str]:
    """The path a lapsed session was thrown off, and what to call it.

    State 5 of the sign-in design promises the return trip is one code, not a
    re-navigation, so the notice names the screen. Consumed on read.
    """
    return (request.session.pop(RETURN_TO, '') or '',
            request.session.pop(RETURN_LABEL, '') or '')


def td_required(label: str = ''):
    """Sign-in gate for a console page.

    Remembers the path and its human name on the way out, so the sign-in page
    can say which screen the TD was on and land them back on it.
    """
    def decorator(view):
        @functools.wraps(view)
        def wrapped(request, *args, **kwargs):
            if not request.user.is_authenticated or not request.user.account_id:
                request.session[RETURN_TO] = request.get_full_path()
                request.session[RETURN_LABEL] = label
                return redirect(reverse('console:sign-in'))
            return view(request, *args, **kwargs)
        return wrapped
    return decorator
