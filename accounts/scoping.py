"""
accounts/scoping.py
-------------------
Per-account scoping helpers shared across the app.

Two pieces:

1. `AccountScopedQuerySet` / `AccountScopedManager` — adds a
   `.for_account(account)` method to any model with an `account` FK.
   Use it on the tenant-root models (Player, Course, Tournament,
   Round) so call sites can write `Player.objects.for_account(acct)`
   and be guaranteed cross-account isolation.

2. `AccountScopedAPIView` — DRF mixin that exposes
   `self.current_account` (== request.user.account) and a
   `scoped(queryset)` helper that filters by it.  Views that derive
   from `AccountScopedAPIView` rather than the plain `APIView` get
   account-aware querysets for free.

The pattern is opt-in for now — we add it to new code immediately
and migrate existing views over in a follow-up.  Until every view is
migrated, isolation only matters in scenarios where more than one
account exists (currently just Golden Glove on dev).
"""

from __future__ import annotations

from django.db import models
from rest_framework.exceptions import PermissionDenied


# ---------------------------------------------------------------------------
# Model manager / queryset
# ---------------------------------------------------------------------------

class AccountScopedQuerySet(models.QuerySet):
    """
    Adds `.for_account()` to any model that has an `account` FK.
    Use as: `objects = AccountScopedManager()` on the model.
    """

    def for_account(self, account) -> 'AccountScopedQuerySet':
        if account is None:
            # Defensive: forbid passing None.  An explicit
            # `.filter(account__isnull=True)` is fine if you really
            # want orphans, but `.for_account(None)` is almost always
            # a bug (forgot to authenticate, etc).
            raise ValueError(
                '.for_account(None) is not allowed.  Pass the real '
                'Account instance or use .filter(account=...) directly.'
            )
        return self.filter(account=account)


class AccountScopedManager(models.Manager.from_queryset(AccountScopedQuerySet)):
    """Manager that exposes `.for_account()`."""


# ---------------------------------------------------------------------------
# DRF view mixin
# ---------------------------------------------------------------------------

class AccountScopedAPIView:
    """
    Mixin for DRF views.  Provides:

      * `self.current_account`  — request.user.account, or raises
                                  PermissionDenied if no user / no account.
      * `self.scoped(qs)`       — qs.filter(account=self.current_account)

    Drop into a view's class hierarchy alongside APIView / ModelViewSet:

        class MyView(AccountScopedAPIView, APIView):
            def get(self, request):
                rounds = self.scoped(Round.objects.all())
                ...

    Future cleanup may add `get_queryset()` integration with DRF's
    generic views; for now this is the minimum surface that lets us
    migrate the existing hand-rolled views one at a time.
    """

    @property
    def current_account(self):
        user = getattr(self.request, 'user', None)
        if not user or not user.is_authenticated:
            raise PermissionDenied(
                'Authentication required for account-scoped views.'
            )
        account = getattr(user, 'account', None)
        if account is None:
            # accounts.User.account is NOT NULL so this should be
            # unreachable, but covering it makes a missed migration
            # fail loudly rather than silently leaking data.
            raise PermissionDenied(
                'Authenticated user has no account — refusing to '
                'serve cross-tenant data.'
            )
        return account

    def scoped(self, queryset):
        return queryset.filter(account=self.current_account)
