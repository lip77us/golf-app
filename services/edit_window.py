"""
services/edit_window.py
-----------------------
How long a round's SETUP stays editable.

**The first three holes are the window. The 4th score locks tee box, handicap
index and teams for every game.** A game's own rule may lock a setting EARLIER;
no game's rule extends past the ceiling.

Design proposed four (`~/Downloads/REPLY-2.md`, 12 Sep 2026) and left the
boundary a hole ambiguous. Paul settled both the same day, and the reason he
gave is what pins the number rather than a feel for it: **three scored holes is
exactly one complete Sequoya match, and match 2 has not been set.** A window
that reaches hole 4 would be redrawing a pairing the second match is already
being played under.

Three holes is also enough to find the three things this exists for — the wrong
tee, the wrong teams, the wrong forced handicap. All three announce themselves
on the first green.

It also BOUNDS THE REWRITE. `HoleScore.handicap_strokes` and `net_score` are
stored rather than computed, so accepting a tee or index change means rewriting
rows, not recomputing a view. Under this ceiling the maximum rewrite is three
holes per golfer, never eighteen.

The ceiling lives here, as one constant, because it is one rule for every game.
A 3 written into each service is how eleven games end up with eleven rules
again — which is the thing the matrix was trying to stop.

**Sixes is not an exception.** Its second match starts at hole 7, so Design's
alternative — lock when the second match begins — could never have fired under
any ceiling this size. Paul settled it: the ceiling applies to Sixes as it does
to everything else, and the trigger is deliberately not built.
"""

# Scored holes through which setup stays editable. The 4th score closes it —
# which is the hole Sequoya's second match starts on, and that is the point.
EDIT_CEILING_HOLES = 3


def scored_holes(foursome) -> int:
    """How many holes of this foursome have a REAL gross score on them.

    Holes, not rows: a group is through 3 when three holes are in, whether
    that is three golfers or four. And phantom scores are not somebody playing
    — the Sixes phantom padding a three-ball must not spend the window — which
    is the same rule the tee-box editor has always used.
    """
    from scoring.models import HoleScore
    return (HoleScore.objects
            .filter(foursome=foursome, gross_score__isnull=False,
                    player__is_phantom=False)
            .values('hole_number').distinct().count())


def ceiling_for(foursome) -> int:
    """This foursome's window — the shared ceiling, or a game's stricter own.

    The rule allows a game to lock EARLIER than the ceiling and never later, so
    this is the only place a game may narrow it. One game does.

    **Banker is zero.** Every hole is a separately negotiated bet, priced
    against the strokes in play at the moment it is struck — so a bet made on
    the 1st cannot survive its inputs changing on the 2nd. There is no window
    in which a correction is free, because the first hole has already been
    bought. Paul, 12 Sep: support it before any holes are scored, and not
    after.

    This is NOT `BankerLocked`, which is a hole's betting window closing. Two
    different locks, both real, deliberately named apart.
    """
    from games.models import BankerGame
    if BankerGame.objects.filter(foursome=foursome).exists():
        return 0
    return EDIT_CEILING_HOLES


def edits_open(foursome) -> bool:
    """True while setup may still be corrected — at or under the ceiling."""
    return scored_holes(foursome) <= ceiling_for(foursome)


def closed_reason(noun: str = 'Teams', because: str = '') -> str:
    """The refusal, phrased so it names the rule rather than the failure.

    **"after the first three holes", not "after 3 holes are scored"** — the
    second reads as though the third score is the one that shuts it, and the
    third hole is inside the window. A greyed control with no explanation is
    the thing that made this read as a bug in the first place.

    Every game that locks on the ceiling builds its message here, `because`
    carrying the one clause that is its own. The first version let each service
    write its own f-string and the two had already drifted apart by the time
    the number changed from four to three — which is the same failure the
    constant itself exists to prevent, one layer up.
    """
    tail = because or 'the holes already played were scored against them'
    return (f'{noun} are locked after the first {EDIT_CEILING_HOLES} holes — '
            f'{tail}. Start a new match with the same golfers to change this.')


def banker_closed_reason(noun: str = 'Settings') -> str:
    """Banker's refusal, which has to say something different.

    The shared copy offers the first three holes; Banker offers none, and a
    golfer told he is locked "after the first 3 holes" on the 1st green would
    reasonably think it a bug. So it names the reason instead of the window.
    """
    return (f'{noun} are locked once a hole is scored — every Banker hole is '
            f'its own bet, priced against the strokes in play when it was '
            f'struck. Start a new match to change this.')
