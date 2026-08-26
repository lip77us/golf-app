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
BUILDERS = {
    'sixes': _sixes,
}


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

    state = build(foursome, player_id, final=final)
    if not state:
        return {}
    # The discriminator rides on every state, so the Swift never has to infer
    # the layout from a string meant for a human.
    state['kind'] = slug
    return state
