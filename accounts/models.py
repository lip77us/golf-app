"""
accounts/models.py
------------------
Multi-tenant Account model and a custom User that lives inside one.

An Account is the tenant boundary — every Player, Course, Tournament,
Round (etc.) row belongs to exactly one Account, and one user sees only
the data inside their Account.

Multiple Users may share the same Account; the `is_account_admin` flag
elevates a user to administer their Account (invite members, configure
games, etc.).  The Django `is_staff` / `is_superuser` flags are
reserved for ops-level access to the Django admin site and are NOT
used for app-level authorization.

(account, username) is unique together — the same username may exist
in different Accounts so two independent groups can both have a
"paul" without collision.  This is enforced via a UniqueConstraint
because we can't simply mark `username` non-unique while keeping the
inherited AbstractUser behavior.
"""

import hashlib
import secrets
from datetime import timedelta

from django.conf import settings
from django.contrib.auth.models import AbstractUser, UserManager
from django.contrib.auth.validators import UnicodeUsernameValidator
from django.db import models
from django.db.models.functions import Lower
from django.utils import timezone


class Account(models.Model):
    """
    A tenant — the unit of data isolation.  Created by the primary
    administrator at sign-up time and named however they like (e.g.
    "Golden Glove", "Lipkin Family", "Saturday Group").
    """
    name        = models.CharField(
                    max_length=80,
                    help_text="Display name chosen by the account owner. "
                              "Unique case-insensitively.",
                  )
    created_at  = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            # Case-insensitive uniqueness on name so "Golden Glove" and
            # "golden glove" can't both exist.
            models.UniqueConstraint(
                Lower('name'),
                name='accounts_account_name_ci_unique',
            ),
        ]
        ordering = ['name']

    def __str__(self) -> str:
        return self.name


class AccountUserManager(UserManager):
    """
    Custom manager that creates users with an explicit account.

    Django's default UserManager.create_user signature is
    (username, email, password, **extra), and create_superuser adds
    is_staff=True / is_superuser=True.  We extend create_user to
    require `account` so test fixtures and views can't accidentally
    create a tenantless user.
    """

    def create_user(self, username, email=None, password=None,
                    *, account=None, **extra):
        if account is None:
            raise ValueError(
                "Users must belong to an Account — pass account=<Account>."
            )
        extra['account'] = account
        return super().create_user(username, email, password, **extra)

    def create_superuser(self, username, email=None, password=None,
                         *, account=None, **extra):
        # Superusers are ops-level and still need an account home; the
        # bootstrap migration creates the Golden Glove account up front
        # so this is always callable in fixtures and management commands.
        if account is None:
            raise ValueError(
                "Superusers must also belong to an Account — pass "
                "account=<Account>."
            )
        extra['account']           = account
        extra['is_account_admin']  = True
        return super().create_superuser(username, email, password, **extra)


class User(AbstractUser):
    """
    Per-account user.

    `account` scopes the user to one tenant.  `is_account_admin` flags
    users who can administer their account (invite members, configure
    games at tournament level, etc.) — distinct from Django's
    `is_staff` flag, which is reserved for the Django admin site and
    not used for any app-level authorization.

    `username` is overridden to drop AbstractUser's global unique=True:
    two accounts can each have a "paul".  The (account, username)
    UniqueConstraint below keeps uniqueness intact within an account.
    Authentication runs through `accounts.backends.AccountBackend`,
    which disambiguates by also taking the account name.
    """
    username = models.CharField(
        max_length=150,
        validators=[UnicodeUsernameValidator()],
        error_messages={
            'unique': 'A user with that username already exists in this '
                      'account.',
        },
        help_text='150 characters or fewer.  Letters, digits and '
                  '@/./+/-/_ only.  Unique within the account.',
    )
    account = models.ForeignKey(
        Account,
        on_delete=models.CASCADE,
        related_name='members',
        help_text="Tenant this user belongs to.",
    )
    is_account_admin = models.BooleanField(
        default=False,
        help_text="Can administer this user's account: invite members, "
                  "set roles, configure games, etc.  Multiple admins per "
                  "account allowed.",
    )
    is_support = models.BooleanField(
        default=False,
        help_text="Halved support staff: READ-ONLY cross-account access to any "
                  "round's leaderboard/scorecard for diagnosing reported issues. "
                  "Does NOT grant write access. Every support lookup is logged "
                  "(SupportAccessLog).",
    )
    # Phone-first identity (freemium design §12): the verified cell number is
    # the primary login credential.  Stored normalized to E.164 (e.g.
    # "+14155551234").  GLOBALLY unique so a number maps to exactly one user →
    # one account.  `null=True` (not just blank) so the many legacy
    # password-only users coexist — Postgres permits multiple NULLs under a
    # unique column, while the constraint still blocks two users sharing a
    # number.  Empty string is NOT used here (it would collide on the unique
    # index); use NULL for "no phone".
    phone = models.CharField(
        max_length=20,
        unique=True,
        null=True,
        blank=True,
        help_text="Verified login phone in E.164 form.  NULL for "
                  "password-only (legacy) users.",
    )
    phone_verified_at = models.DateTimeField(
        null=True, blank=True,
        help_text="When the phone number was last verified via SMS OTP.",
    )
    # Personal viral invite code → public landing page at /i/<code>/.  Minted
    # lazily on first use (see ensure_invite_code); stable per user thereafter.
    invite_code = models.CharField(
        max_length=12, unique=True, null=True, blank=True,
        help_text="Stable per-user code for the public invite link /i/<code>/.",
    )
    # Per-category push toggles (see services/push.NOTIFICATION_CATEGORIES).
    # Missing key = use the category default (mostly on). OS-level permission is
    # separate and checked on the device.
    notification_prefs = models.JSONField(default=dict, blank=True)

    objects = AccountUserManager()

    def ensure_invite_code(self) -> str:
        """
        Return this user's invite code, minting a stable one on first call.

        Uses the same scheme as Round.watch_token: an 8-char base32-ish code
        (no 0/1/I/O) with collision retry — 32**8 ≈ 1.1 trillion combinations.
        """
        if not self.invite_code:
            import secrets
            import string
            alphabet = string.ascii_uppercase + '23456789'
            for _ in range(5):
                candidate = ''.join(secrets.choice(alphabet) for _ in range(8))
                if not type(self).objects.filter(invite_code=candidate).exists():
                    self.invite_code = candidate
                    break
            self.save(update_fields=['invite_code'])
        return self.invite_code

    class Meta:
        constraints = [
            # Same username may exist in different accounts, but never
            # twice within one.  Case-insensitive so "Paul" and "paul"
            # collide in the same account (same convention as Account.name).
            models.UniqueConstraint(
                Lower('username'), 'account',
                name='accounts_user_account_username_ci_unique',
            ),
        ]


    def __str__(self) -> str:
        return f"{self.username}@{self.account.name}"


# How long an issued OTP stays valid, and how many wrong guesses a single
# code tolerates before it's burned.  Tuned for SMS-delivery latency vs.
# brute-force resistance (a 6-digit space + 5 attempts + 10-min window).
OTP_TTL          = timedelta(minutes=10)
OTP_MAX_ATTEMPTS = 5


class PhoneOTP(models.Model):
    """
    A one-time SMS passcode for phone-based login (freemium design §12).

    The plaintext code is NEVER stored — only a salted hash — so a DB leak
    doesn't expose live codes.  `issue()` returns the plaintext exactly once,
    for the SMS layer to deliver; everything afterward works off the hash.

    A code is "live" while `consumed_at` is NULL and it hasn't expired.
    Issuing a new code for a phone consumes any prior live codes, so only the
    newest matters.
    """
    phone       = models.CharField(max_length=20, db_index=True)
    code_hash   = models.CharField(max_length=64)
    created_at  = models.DateTimeField(auto_now_add=True)
    expires_at  = models.DateTimeField()
    consumed_at = models.DateTimeField(null=True, blank=True)
    attempts    = models.PositiveSmallIntegerField(default=0)

    class Meta:
        indexes = [models.Index(fields=['phone', '-created_at'])]

    def __str__(self) -> str:
        return f"OTP({self.phone}, consumed={self.consumed_at is not None})"

    @staticmethod
    def _hash(code: str) -> str:
        # SECRET_KEY acts as a server-side pepper so the hash isn't a plain
        # rainbow-table lookup over the tiny 6-digit space.
        return hashlib.sha256(f"{code}{settings.SECRET_KEY}".encode()).hexdigest()

    @classmethod
    def issue(cls, phone: str) -> str:
        """Burn prior live codes, mint a fresh 6-digit code, return plaintext."""
        now = timezone.now()
        cls.objects.filter(phone=phone, consumed_at__isnull=True).update(consumed_at=now)
        code = f"{secrets.randbelow(1_000_000):06d}"
        cls.objects.create(
            phone=phone,
            code_hash=cls._hash(code),
            expires_at=now + OTP_TTL,
        )
        return code

    @classmethod
    def check_code(cls, phone: str, code: str) -> bool:
        """
        Validate `code` against the newest live OTP for `phone`.

        Increments the attempt counter; burns the code on success or once the
        attempt cap is exceeded.  Returns True only on an exact, in-window,
        under-cap match.  All failure modes return False (the caller surfaces a
        single non-enumerating "invalid or expired" message).
        """
        otp = (
            cls.objects
            .filter(phone=phone, consumed_at__isnull=True)
            .order_by('-created_at')
            .first()
        )
        if otp is None:
            return False
        now = timezone.now()
        if now >= otp.expires_at:
            return False
        otp.attempts += 1
        if otp.attempts > OTP_MAX_ATTEMPTS:
            otp.consumed_at = now
            otp.save(update_fields=['attempts', 'consumed_at'])
            return False
        if otp.code_hash != cls._hash(code):
            otp.save(update_fields=['attempts'])
            return False
        otp.consumed_at = now
        otp.save(update_fields=['attempts', 'consumed_at'])
        return True


class DeviceToken(models.Model):
    """
    A device's push (FCM) registration token for a user. A user may have several
    (phone + tablet). Registered on login / app start / token refresh; removed on
    logout and account deletion. Stale tokens are pruned when FCM reports them
    unregistered.
    """
    PLATFORMS = [('ios', 'iOS'), ('android', 'Android')]

    user       = models.ForeignKey(
                    'accounts.User', on_delete=models.CASCADE,
                    related_name='device_tokens')
    token      = models.CharField(max_length=255, unique=True)
    platform   = models.CharField(max_length=10, choices=PLATFORMS, blank=True)
    updated_at = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f'DeviceToken({self.user_id}, {self.platform})'


class SentNotification(models.Model):
    """
    Idempotency log for event-driven pushes. Skins/leaderboards recompute on
    every score edit, so we record a stable `dedup_key` (e.g.
    "skin_won:round=42:hole=7") and only send when inserting a new key succeeds.
    """
    event_type = models.CharField(max_length=40)
    dedup_key  = models.CharField(max_length=200, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.dedup_key


class SupportAccessLog(models.Model):
    """
    Audit trail for support staff (User.is_support / superuser) opening a
    round they don't own, to diagnose a reported issue. One row per lookup so
    cross-tenant access is always accountable.
    """
    user         = models.ForeignKey(
                     'accounts.User', on_delete=models.SET_NULL, null=True,
                     related_name='+')
    round        = models.ForeignKey(
                     'tournament.Round', on_delete=models.SET_NULL, null=True,
                     related_name='+')
    account_name = models.CharField(max_length=255, blank=True,
                     help_text="Snapshot of the viewed account's name.")
    query        = models.CharField(max_length=64, blank=True,
                     help_text="What support typed (watch token or round id).")
    created_at   = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        who = self.user.username if self.user else '?'
        return f'SupportAccess({who} → round {self.round_id} @ {self.created_at:%Y-%m-%d %H:%M})'
