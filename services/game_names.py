"""
services/game_names.py
----------------------
The name a game is called in front of someone who does not work here.

GameType.label is an INTERNAL label: it disambiguates rows in the admin and
in code, so it carries qualifiers that mean nothing to a golfer. The clearest
case is 'low_net_round', whose label is "Low Net (Round)" — the parenthetical
exists only to separate it from 'low_net' ("Low Net Championship"). The app
has always shown that game as "Stroke Play"; the label leaked into a share
message ("I'm playing Low Net (Round) at Tilden Park") because the invite
endpoint reached for .label directly.

Every user-facing surface — share text, Open Graph title and description, the
observer page — goes through here, so the two names cannot drift again.
"""
from core.models import GameType


# Games whose public name differs from GameType.label. Keep this map SMALL:
# an entry here is a sign the label itself is carrying internal baggage, and
# the better fix is usually a clearer label.
_PUBLIC_OVERRIDES = {
    # The app's own catalog calls this "Stroke Play" (mobile game_catalog.dart).
    GameType.LOW_NET_ROUND.value: 'Stroke Play',
}


def public_game_name(slug: str) -> str:
    """
    The public name for a game slug, or '' when the slug is unknown.

    Returns '' rather than the raw slug for anything the enum does not know
    (an older round, a renamed game) — saying nothing reads better than
    printing 'low_net_round' at someone.
    """
    if not slug:
        return ''
    override = _PUBLIC_OVERRIDES.get(slug)
    if override:
        return override
    try:
        return GameType(slug).label
    except ValueError:
        return ''


def public_game_names(slugs) -> list:
    """Public names for several slugs, dropping unknowns and duplicates."""
    out = []
    for s in slugs or []:
        name = public_game_name(s)
        if name and name not in out:
            out.append(name)
    return out
