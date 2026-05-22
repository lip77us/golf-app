"""
accounts/backends.py
--------------------
Custom Django authentication backend that disambiguates users by
(account_name, username, password) instead of (username, password).

Two users named "paul" in two different accounts is intentional —
every group brings their own roster.  The default ModelBackend looks
up by username alone and would either find the wrong row or raise
MultipleObjectsReturned, so we slot AccountBackend in front of it.

ModelBackend remains in AUTHENTICATION_BACKENDS as a fallback for
flows that don't carry an account context (Django admin, management
commands, etc.).  Phase 4 may switch the admin login form to require
account_name and drop ModelBackend entirely.
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.backends import ModelBackend

from .models import Account


class AccountBackend(ModelBackend):
    """
    Authenticate against (account_name, username, password).

    Caller is expected to pass account_name as a kwarg to
    `authenticate()` — typically from the LoginView reading the
    JSON request body.  If account_name is missing or no account
    matches, returns None and falls through to the next backend.
    """

    def authenticate(self, request, username=None, password=None,
                     account_name=None, **kwargs):
        if not (username and password and account_name):
            return None

        try:
            account = Account.objects.get(name__iexact=account_name.strip())
        except Account.DoesNotExist:
            return None

        User = get_user_model()
        try:
            user = User.objects.get(
                username__iexact=username.strip(),
                account=account,
            )
        except User.DoesNotExist:
            # Run the default password hasher even when the user doesn't
            # exist — keeps response times constant so an attacker can't
            # distinguish "no such user" from "bad password" via timing.
            User().set_password(password)
            return None

        if not user.check_password(password):
            return None
        if not self.user_can_authenticate(user):
            return None
        return user
