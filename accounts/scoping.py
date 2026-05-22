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
from django.shortcuts import get_object_or_404
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import IsAuthenticated


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


# ---------------------------------------------------------------------------
# Registry + helpers for account-scoped lookups on any model
# ---------------------------------------------------------------------------
#
# Each entry in SCOPE_PATHS maps a model (referenced by 'app_label.Model' so
# we don't have to import every model up front) to the ORM lookup path that
# reaches its Account.  Direct tenant roots are just 'account'; child models
# follow their FK chain — e.g. Foursome rows live under a Round, so
# `foursome.round.account` is the chain and the lookup string is
# 'round__account'.
#
# Adding a new model: also add it here.  Models not registered raise
# UnknownTenantModel on lookup, which is the safest failure mode (no
# accidental "filter by nothing" leaks).

SCOPE_PATHS: dict[str, str] = {
    # Tenant roots — `account` directly on the model.
    'accounts.User':                  'account',
    'core.Player':                    'account',
    'core.Course':                    'account',
    'tournament.Tournament':          'account',
    'tournament.Round':               'account',

    # Course children.
    'core.Tee':                       'course__account',

    # Tournament / round children.
    'tournament.Foursome':            'round__account',
    'tournament.FoursomeMembership':  'foursome__round__account',
    'tournament.MatchPlayChampionship': 'tournament__account',
    'tournament.ChampionshipSeed':    'championship__tournament__account',
    'tournament.TeamTournament':      'tournament__account',
    'tournament.TournamentTeam':      'tournament__tournament__account',
    'tournament.RyderCupRoundConfig': 'round__account',
    'tournament.RyderCupFoursomeConfig': 'round_config__round__account',
    'tournament.RyderCupIrishRumblePairing': 'round_config__round__account',
    'tournament.RyderCupMatchPoints': 'round_config__round__account',

    # Foursome-attached game configs / results.
    'games.SixesSegment':             'foursome__round__account',
    'games.SixesTeam':                'segment__foursome__round__account',
    'games.SixesHoleResult':          'segment__foursome__round__account',
    'games.Points531Game':            'foursome__round__account',
    'games.Points531PlayerHoleResult': 'game__foursome__round__account',
    'games.SkinsGame':                'foursome__round__account',
    'games.SkinsHoleResult':          'game__foursome__round__account',
    'games.SkinsPlayerHoleResult':    'game__foursome__round__account',
    'games.MultiSkinsGame':           'round__account',
    'games.MultiSkinsHoleResult':     'game__round__account',
    'games.NassauGame':               'foursome__round__account',
    'games.NassauTeam':               'game__foursome__round__account',
    'games.NassauHoleScore':          'game__foursome__round__account',
    'games.NassauPress':              'game__foursome__round__account',
    'games.IrishRumbleConfig':        'round__account',
    'games.IrishRumbleSegmentResult': 'round__account',
    'games.LowNetRoundConfig':        'round__account',
    'games.LowNetChampionshipConfig': 'tournament__account',
    'games.PinkBallConfig':           'round__account',
    'games.PinkBallHoleResult':       'round__account',
    'games.PinkBallResult':           'round__account',
    'games.ScrambleHoleScore':        'foursome__round__account',
    'games.ScrambleResult':           'round__account',
    'games.MatchPlayBracket':         'foursome__round__account',
    'games.QuotaNassauGame':          'foursome__round__account',

    # Scoring records hang off Foursome (or Round / Tournament).
    'scoring.HoleScore':              'foursome__round__account',
    'scoring.StablefordResult':       'round__account',
    'scoring.SkinsResult':            'foursome__round__account',
    'scoring.SkinsResultNoCarryover': 'foursome__round__account',
    'scoring.LowNetResult':           'tournament__account',
}


class UnknownTenantModel(Exception):
    """Raised when a model is queried via account_qs without being
    registered in SCOPE_PATHS — fail loud rather than leak."""


def _scope_path_for(model: type) -> str:
    label = f'{model._meta.app_label}.{model.__name__}'
    if label not in SCOPE_PATHS:
        raise UnknownTenantModel(
            f'{label} is not registered in SCOPE_PATHS — add it to '
            'accounts/scoping.py before scoping it.'
        )
    return SCOPE_PATHS[label]


def account_qs(model, account, *, base=None):
    """
    Return a queryset of `model` filtered by `account` via its
    registered scope path.

    Pass `base=` (a pre-filtered queryset on the same model) when you
    want to layer the account filter on top of an existing queryset.
    """
    if account is None:
        raise ValueError('account_qs requires a non-None Account.')
    path = _scope_path_for(model)
    qs = base if base is not None else model.objects.all()
    return qs.filter(**{path: account})


def account_get_or_404(model, account, *, base=None, **kwargs):
    """
    `get_object_or_404(model, **kwargs)` plus the account scoping
    filter — so an attacker poking other accounts' PKs gets a 404,
    not the row.
    """
    qs = account_qs(model, account, base=base)
    return get_object_or_404(qs, **kwargs)


# ---------------------------------------------------------------------------
# DRF permission
# ---------------------------------------------------------------------------

class IsAccountMember(IsAuthenticated):
    """
    Authenticated + has an Account attached.  The accounts.User model
    enforces NOT NULL on `account`, so the second check is defence in
    depth against a misconfigured fixture.
    """
    def has_permission(self, request, view) -> bool:
        if not super().has_permission(request, view):
            return False
        return getattr(request.user, 'account_id', None) is not None


class IsAccountAdmin(IsAccountMember):
    """
    Same as IsAccountMember but requires is_account_admin=True.
    Used for endpoints that mutate account-wide state (invite users,
    rename the account, etc.).
    """
    def has_permission(self, request, view) -> bool:
        return (super().has_permission(request, view)
                and bool(getattr(request.user, 'is_account_admin', False)))
