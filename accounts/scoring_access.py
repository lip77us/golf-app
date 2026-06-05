"""
accounts/scoring_access.py
--------------------------
Authorization for delegated cross-account scoring.

A user may act on a foursome / round / tournament if it's in their OWN account,
or they're a **phone-matched designated scorer** (`FoursomeMembership.is_scorer`
on a member whose `Player.phone` normalizes to the user's verified phone).
Leaderboard READS additionally allow any **phone-matched participant** — which
preserves Friends Phase 2a "Shared with me" (the scorer is a participant too, so
it's covered automatically).

These resolvers mirror `account_get_or_404`: they raise Http404 when
unauthorized (no info leak) and return the SAME object for own-account users, so
swapping them into existing views is behaviour-preserving and only *adds* the
scorer path (and closes the previously-open score/leaderboard endpoints).
"""
from django.http import Http404

from .phone import normalize
from .scoping import account_qs


def _phone(user):
    return getattr(user, 'phone', None)


def user_scores_foursome(user, foursome) -> bool:
    """True if `user` is a designated (phone-matched) scorer of `foursome`."""
    phone = _phone(user)
    if not phone:
        return False
    return any(
        m.is_scorer and m.player.phone and normalize(m.player.phone) == phone
        for m in foursome.memberships.all()
    )


def _round_player_phones_match(user, round_obj) -> bool:
    """True if any player in any foursome of `round_obj` carries user's phone."""
    phone = _phone(user)
    if not phone:
        return False
    return any(
        m.player.phone and normalize(m.player.phone) == phone
        for fs in round_obj.foursomes.all()
        for m in fs.memberships.all()
    )


def foursome_for_scorer(user, pk, *, base=None):
    """Foursome if own-account OR a designated scorer; else 404. (WRITE/score)"""
    from tournament.models import Foursome
    own = account_qs(Foursome, user.account, base=base).filter(pk=pk).first()
    if own is not None:
        return own
    qs = base if base is not None else (
        Foursome.objects.select_related('round__course')
        .prefetch_related('memberships__player')
    )
    fs = qs.filter(pk=pk).first()
    if fs is not None and user_scores_foursome(user, fs):
        return fs
    raise Http404('No such foursome.')


def round_for_scorer(user, pk, *, base=None):
    """Round if own-account OR the user scores any of its foursomes. (open to score)"""
    from tournament.models import Round
    own = account_qs(Round, user.account, base=base).filter(pk=pk).first()
    if own is not None:
        return own
    qs = base if base is not None else Round.objects.select_related('course')
    rnd = qs.prefetch_related('foursomes__memberships__player').filter(pk=pk).first()
    if rnd is not None and any(
        user_scores_foursome(user, fs) for fs in rnd.foursomes.all()
    ):
        return rnd
    raise Http404('No such round.')


def round_for_reader(user, pk, *, base=None):
    """Round if own-account OR a phone-matched participant (covers scorer +
    "Shared with me"). (READ — leaderboard)"""
    from tournament.models import Round
    own = account_qs(Round, user.account, base=base).filter(pk=pk).first()
    if own is not None:
        return own
    qs = base if base is not None else Round.objects.select_related('course', 'tournament')
    rnd = qs.prefetch_related('foursomes__memberships__player').filter(pk=pk).first()
    if rnd is not None and _round_player_phones_match(user, rnd):
        return rnd
    raise Http404('No such round.')


def tournament_for_reader(user, pk, *, base=None):
    """Tournament if own-account OR a phone-matched participant in any of its
    rounds. (READ — tournament leaderboard)"""
    from tournament.models import Tournament
    own = account_qs(Tournament, user.account, base=base).filter(pk=pk).first()
    if own is not None:
        return own
    qs = base if base is not None else Tournament.objects.all()
    t = qs.prefetch_related(
        'rounds__foursomes__memberships__player',
    ).filter(pk=pk).first()
    if t is not None:
        phone = _phone(user)
        if phone and any(
            m.player.phone and normalize(m.player.phone) == phone
            for r in t.rounds.all()
            for fs in r.foursomes.all()
            for m in fs.memberships.all()
        ):
            return t
    raise Http404('No such tournament.')
