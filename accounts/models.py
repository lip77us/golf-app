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

from django.contrib.auth.models import AbstractUser, UserManager
from django.db import models
from django.db.models.functions import Lower


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
    """
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

    objects = AccountUserManager()

    class Meta:
        constraints = [
            # Same username may exist in different accounts, but never
            # twice within one.
            models.UniqueConstraint(
                fields=['account', 'username'],
                name='accounts_user_account_username_unique',
            ),
        ]

    def __str__(self) -> str:
        return f"{self.username}@{self.account.name}"
