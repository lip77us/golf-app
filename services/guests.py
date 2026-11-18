"""One-round guests (`handoff-golfer-indexes 2`, section 0).

**Your golfers are Halved members and golfers with a GHIN.** A golfer with
neither is a *guest*: added with "Add a new golfer", scored and texted for this
round or tournament, and then not listed again. Nothing is deleted - the row
stays because every score references it - the golfer is simply left out of the
lists once none of their rounds is still going.

A guest that has never been in a round is still listed: it was created seconds
ago and is waiting to be seated.
"""
from accounts.phone import normalize


def on_app_phones_for(players):
    from django.contrib.auth import get_user_model
    normalized = {normalize(p.phone) for p in players if p.phone}
    normalized.discard(None)
    if not normalized:
        return set()
    return set(get_user_model().objects.filter(phone__in=normalized)
               .values_list('phone', flat=True))


def is_guest(player, on_app_phones) -> bool:
    """Not on Halved and no GHIN."""
    if player.user_id or (player.ghin or '').strip():
        return False
    n = normalize(player.phone) if player.phone else None
    return not (n and n in on_app_phones)


def listable(players, on_app_phones=None):
    """The golfers worth listing: members, golfers with a GHIN, and guests who
    are still in a round that has not finished (or were never in one yet)."""
    from core.models import RoundStatus
    from tournament.models import FoursomeMembership

    players = list(players)
    if on_app_phones is None:
        on_app_phones = on_app_phones_for(players)
    guests = [p for p in players if is_guest(p, on_app_phones)]
    if not guests:
        return players
    ids = [p.id for p in guests]
    played = set(FoursomeMembership.objects.filter(player_id__in=ids)
                 .values_list('player_id', flat=True))
    active = set(FoursomeMembership.objects
                 .filter(player_id__in=ids)
                 .exclude(foursome__round__status=RoundStatus.COMPLETE)
                 .values_list('player_id', flat=True))
    hidden = {p.id for p in guests if p.id in played and p.id not in active}
    return [p for p in players if p.id not in hidden]
