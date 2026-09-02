"""
services/live_activity_registry.py
----------------------------------
Which game owns the round's lock screen, and what its five slots say
(docs/design-review/handoff-live-activities/SPEC.md).

**One activity per round, owned by the primary game named at setup.** There is
no ranking of games by newsworthiness and nothing to arbitrate at runtime — the
group already answered it when they set the round up. A Nassau with a skins
side game gets the Nassau card and no skins card.

Every state carries a ``kind``. The Swift side switches layouts on it rather
than reading the header's display string, because two of these cards are not
the same composition: Nassau has two numbers where Sixes has one, and Rabbit's
run strip is a computed list where Sixes had three fixed pips.
"""
import logging

logger = logging.getLogger(__name__)


def primary_game(rnd) -> str:
    """The round's primary game slug.

    ``primary_game`` is null on tournament and legacy rounds, where the set was
    never an explicit pick — fall back to the first active game, the same rule
    the watch pages and the share card already use.
    """
    slug = rnd.primary_game or ''
    if not slug:
        games = rnd.active_games or []
        slug = games[0] if games else ''
    return slug


def foursome_for(rnd, user, slug):
    """The group whose board belongs on this user's lock screen, and the
    player_id the money line is written for.

    A golfer gets their own group.  A watcher — or a TD reading someone else's
    round — gets the first group running the game and no money line, because
    the money is the one slot that is personal; everything else on the card is
    the same string on every phone.
    """
    from accounts.phone import normalize
    phone = normalize(getattr(user, 'phone', None) or '') or None

    running = [fs for fs in rnd.foursomes.all()
               if slug in (set(fs.active_games or [])
                           | set(rnd.active_games or []))]
    for fs in running:
        for m in fs.memberships.all():
            mine = (m.player.user_id == user.id
                    or (phone and m.player.phone
                        and normalize(m.player.phone) == phone))
            if mine:
                return fs, m.player_id
    return (running[0] if running else None), None


def holes_played(foursome) -> int:
    """Holes the group has finished — the highest hole EVERY golfer has a score
    on, not the highest anyone has.  A card reads 'thru 7' when the group is
    through 7; one player running ahead does not move it."""
    from scoring.models import HoleScore
    counts = {}
    for hs in HoleScore.objects.filter(foursome=foursome,
                                       gross_score__isnull=False):
        counts[hs.hole_number] = counts.get(hs.hole_number, 0) + 1
    size = foursome.memberships.count()
    done = [h for h, n in counts.items() if n >= size]
    return max(done) if done else 0


def gross_to_par(summary, player_id):
    """The reader's own gross against par, from any game's summary.

    **The umbrella packet puts this on every state of every card** — it is the
    number a golfer checks without meaning to and the only personal figure a
    neutral board can afford. `None` when the reader is not playing (a watcher)
    or has no scores yet.

    One implementation on purpose. There were three, each guessing at the key
    a summary uses for its per-hole scores, and Nassau's guessed a key its own
    summary does not have (`players`, where it emits `scores`) — so the Nassau
    card silently dropped the gross figure from its footer for every reader,
    on every hole. A helper that returns None on a shape mismatch fails
    invisibly, which is exactly why there must only be one of it.

    The key varies by game and the alternatives are checked in order rather
    than normalised at the source, because these summaries are the app's own
    long-standing API shapes and are read by screens well outside this module.
    """
    if player_id is None:
        return None
    total, played = 0, 0
    for hole in (summary.get('holes') or []):
        par = hole.get('par')
        entries = (hole.get('scores') or hole.get('players')
                   or hole.get('entries') or [])
        for e in entries:
            if e.get('player_id') != player_id:
                continue
            gross = e.get('gross')
            if gross is not None and par:
                total  += gross - par
                played += 1
    return total if played else None


# ---------------------------------------------------------------------------
# The registry
# ---------------------------------------------------------------------------

def _sixes(foursome, player_id, *, final):
    from services.live_activity import sixes_activity_state, sixes_final_state
    if final:
        return sixes_final_state(foursome, player_id=player_id)
    return sixes_activity_state(foursome, player_id=player_id,
                                thru=holes_played(foursome))


# slug -> builder.  A game absent from here has no card, which is the answer
# for every side game and for the shapes design has not drawn — Triple Nassau
# among them, where three simultaneous pairings will not fit two rows.
def _rabbit(foursome, player_id, *, final):
    from services.live_activity_rabbit import rabbit_activity_state
    if final:
        # TODO: the closing frame — what you won and who to see.
        return {}
    return rabbit_activity_state(foursome, player_id=player_id,
                                 thru=holes_played(foursome))


def _nassau(foursome, player_id, *, final):
    from services.live_activity_nassau import nassau_activity_state
    if final:
        return {}   # TODO: the closing frame
    return nassau_activity_state(foursome, player_id=player_id,
                                 thru=holes_played(foursome))


def _skins(foursome, player_id, *, final):
    from services.live_activity_skins import (skins_activity_state,
                                              skins_final_state)
    if final:
        return skins_final_state(foursome, player_id=player_id)
    return skins_activity_state(foursome, player_id=player_id,
                                thru=holes_played(foursome))


def _match(foursome, player_id, *, final, slug):
    from services.live_activity_match import (match_activity_state,
                                              match_final_state)
    if final:
        return match_final_state(foursome, slug=slug, player_id=player_id)
    return match_activity_state(foursome, slug=slug, player_id=player_id,
                                thru=holes_played(foursome))


BUILDERS = {
    'sixes'   : _sixes,
    'rabbit'  : _rabbit,
    'nassau'  : _nassau,
    'skins'   : _skins,
    # Singles and fourball are ONE card — a single match between two sides over
    # eighteen holes, differing only in how many names sit on a side. Two
    # builders differing by a conjunction would drift apart within a release,
    # so both slugs land on the same one and it declares `kind = 'match'`.
    'match_18': _match,
    'fourball': _match,
    # nassau_nine still rides the NassauGame model as one match but is a
    # PARTIAL round — its holes-remaining is not 18 minus played, so it does
    # not fit this card's state slot and is not drawn. Triple Nassau is
    # explicitly not designed: three simultaneous pairings will not fit.
}

# Builders that need to know which slug selected them, because one card serves
# more than one game.
_SLUG_AWARE = {'match_18', 'fourball'}


def board_recipients(rnd) -> set:
    """User ids that should carry this round's board on their lock screen.

    Everyone the round is legitimately readable by, computed FORWARD from the
    round rather than by asking `round_for_reader` once per user — the caller
    is inside a scoring request and the candidate set is four golfers and a
    couple of watchers, while the set of users holding a start token is the
    whole app.

    Three ways in, matching the read rules exactly:
      * a golfer whose Player carries a linked user;
      * a golfer matched by verified phone (the cross-account link the rest of
        the friend model runs on — a friend added by name and number);
      * an invited watcher, likewise phone-matched.

    A watcher belongs here on purpose.  The board is the same string on every
    phone except the money line, and `foursome_for` already withholds that from
    anyone who is not playing.
    """
    from django.contrib.auth import get_user_model
    from accounts.phone import normalize
    from tournament.models import Watcher

    user_ids = set()
    phones   = set()

    for fs in rnd.foursomes.all():
        for m in fs.memberships.all():
            if m.player.user_id:
                user_ids.add(m.player.user_id)
            if m.player.phone:
                p = normalize(m.player.phone)
                if p:
                    phones.add(p)

    for w in Watcher.objects.filter(round=rnd):
        p = normalize(w.phone or '')
        if p:
            phones.add(p)

    if phones:
        User = get_user_model()
        user_ids.update(
            User.objects.filter(phone__in=phones).values_list('id', flat=True))

    return user_ids


def round_has_board(rnd) -> bool:
    """True when this round's primary game has a lock-screen board at all.

    The cheap gate callers use before doing any work — `activity_state` is the
    authority and answers `{}` for anything it cannot build, but a caller
    sitting inside a scoring request wants to know without loading a foursome.

    Adding a game to the lock screen is a builder in BUILDERS and the matching
    `hasLiveActivity` flag on the client's catalog entry — nothing else needs
    to learn the list.
    """
    return primary_game(rnd) in BUILDERS


def activity_state(rnd, user, *, final=False) -> dict:
    """The five slots for whoever owns this round, or ``{}``.

    ``{}`` means "nothing to show" and the app treats it as "do not start" —
    not a game with a card, no group running it, or nothing played yet.
    Deciding it here keeps the client from having to know which games qualify.
    """
    slug = primary_game(rnd)
    build = BUILDERS.get(slug)
    if build is None:
        return {}

    foursome, player_id = foursome_for(rnd, user, slug)
    if foursome is None:
        return {}

    if slug in _SLUG_AWARE:
        state = build(foursome, player_id, final=final, slug=slug)
    else:
        state = build(foursome, player_id, final=final)
    if not state:
        return {}
    # The discriminator rides on every state, so the Swift never has to infer
    # the layout from a string meant for a human.
    #
    # `setdefault`, not assignment: a builder serving several games declares
    # the CARD it draws, and the Swift should switch on that rather than learn
    # that two slugs mean one layout.
    state.setdefault('kind', slug)
    return state
