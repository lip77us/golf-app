"""
services/edit_window.py
-----------------------
How long a round's SETUP stays editable.

**Edits are open through 4 scored holes. After that, tee box, handicap index
and teams are locked for every game.** A game's own rule may lock a setting
EARLIER; no game's rule extends past the ceiling.

Decided in `~/Downloads/REPLY-2.md` (12 Sep 2026), and the reasoning is the one
the round produced: realising on hole 3 that a golfer is on the wrong tee is a
correctable setup mistake. Realising it on hole 14 is a different round. Four
holes is where a fix stops being a fix.

It also BOUNDS THE REWRITE. `HoleScore.handicap_strokes` and `net_score` are
stored rather than computed, so accepting a tee or index change means rewriting
rows, not recomputing a view. Under this ceiling the maximum rewrite is four
holes per golfer, never eighteen.

The ceiling lives here, as one constant, because it is one rule for every game.
A 4 written into each service is how eleven games end up with eleven rules
again — which is the thing the matrix was trying to stop.

**Sixes is not an exception.** Its second match starts at hole 7, so a
second-match trigger would never fire under the ceiling; Paul settled it on
12 Sep — the ceiling applies to Sixes as it does to everything else. The same
number suits Sequoya, whose matches are three holes: four scored holes covers a
complete first match and one hole of the second.
"""

# Scored holes through which setup stays editable. The 5th score closes it.
EDIT_CEILING_HOLES = 4


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


def edits_open(foursome) -> bool:
    """True while setup may still be corrected — at or under the ceiling."""
    return scored_holes(foursome) <= EDIT_CEILING_HOLES


def closed_reason(noun: str = 'Teams') -> str:
    """The refusal, phrased so it names the rule rather than the failure.

    A greyed control with no explanation is the thing that made this read as a
    bug in the first place.
    """
    return (f'{noun} are locked after {EDIT_CEILING_HOLES} holes are scored — '
            f'the holes already played were scored against them. Start a new '
            f'match with the same golfers to change this.')
