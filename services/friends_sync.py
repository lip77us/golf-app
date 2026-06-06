"""
services/friends_sync.py
------------------------
When a phone-matched participant OPENS a shared multi-foursome round (a
tournament or multi-group skins game a TD/friend added them to), mirror two
things into THEIR account so the round is fully usable from their side:

  * the TD (``round.created_by``) is added to their "My Golfers" roster, and
  * the round's course is copied into their account.

Both are idempotent and phone-/key-matched, consistent with the rest of the
phone-match friend model (no permanent FK link). Called from RoundJoinView when
the participant opens the round.
"""
from accounts.phone import normalize
from services.catalog import catalog_from_course, clone_catalog_to_account


def _creator_phone(creator_player):
    """Best phone for the round creator: their login (User.phone, already E.164)
    wins, else their free-text Player.phone. '' when neither is set."""
    user = creator_player.user if creator_player.user_id else None
    if user is not None and getattr(user, 'phone', None):
        return user.phone
    return creator_player.phone or ''


def copy_course_to_account(course, account):
    """Copy `course` (owned by another account) into `account`. Idempotent by
    golf_api_id / synthetic local key. Returns (course, created)."""
    if course.account_id == account.id:
        return course, False
    cc, _ = catalog_from_course(course)
    return clone_catalog_to_account(cc, account)


def ensure_friend(creator_player, account):
    """Ensure the round creator (a Player in the TD's account) exists as a
    Player in `account`, phone-matched so it shows 'On Halved'. Idempotent by
    normalized phone. Returns (player, created), or (None, False) when there's
    no usable phone (can't make it matchable) or it's the same account."""
    from core.models import Player

    if creator_player is None or creator_player.account_id == account.id:
        return None, False

    raw_phone = _creator_phone(creator_player)
    norm = normalize(raw_phone) if raw_phone else None
    if not norm:
        return None, False

    # Already in this roster (match on normalized phone)?
    for p in Player.objects.filter(account=account).exclude(phone=''):
        if normalize(p.phone) == norm:
            return p, False

    player = Player.objects.create(
        account        = account,
        name           = creator_player.name,
        short_name     = creator_player.short_name or '',
        phone          = raw_phone,
        handicap_index = creator_player.handicap_index,
        sex            = creator_player.sex,
        email          = creator_player.email or '',
    )
    return player, True


def ensure_watch_connection(user, *, round=None, tournament=None):
    """When a watcher opens a round/tournament they were invited to, add the
    INVITER to their "My Golfers" so the connection is mutual (the invitee was
    already added to the inviter's roster at invite time). Idempotent. Returns
    a summary dict."""
    from django.db.models import Q
    from tournament.models import Watcher

    result = {'inviter_added': False, 'inviter_player_id': None}
    phone = getattr(user, 'phone', None)
    if not phone:
        return result

    if tournament is not None:
        q = Q(tournament_id=tournament.id)
    else:
        q = Q(round_id=round.id)
        if round.tournament_id:
            q |= Q(tournament_id=round.tournament_id)
    w = (Watcher.objects.filter(phone=phone).filter(q)
         .select_related('invited_by__user').first())
    if w is None or w.invited_by is None:
        return result
    player, created = ensure_friend(w.invited_by, user.account)
    result['inviter_added'] = created
    result['inviter_player_id'] = player.id if player else None
    return result


def ensure_roster_player(account, raw_phone, name):
    """Ensure a Player with this (normalized) phone exists in `account`'s
    roster — used when inviting a watcher by number so they land in My Golfers.
    Idempotent by normalized phone. Returns (player, created), or (None, False)
    when there's no usable phone."""
    from core.models import Player

    norm = normalize(raw_phone) if raw_phone else None
    if not norm:
        return None, False
    for p in Player.objects.filter(account=account).exclude(phone=''):
        if normalize(p.phone) == norm:
            return p, False
    player = Player.objects.create(
        account=account, name=(name or 'Guest'), phone=raw_phone,
        handicap_index=0, sex='M',
    )
    return player, True


def sync_shared_round(user, round_obj):
    """Mirror the TD + course of `round_obj` into `user.account`. Idempotent.
    Returns a summary dict the API can echo back."""
    friend, friend_created = ensure_friend(round_obj.created_by, user.account)
    course, course_created = copy_course_to_account(round_obj.course, user.account)
    return {
        'td_player_id': friend.id if friend else None,
        'td_added':     friend_created,
        'course_id':    course.id,
        'course_added': course_created,
    }
