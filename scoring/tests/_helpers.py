"""
scoring/tests/_helpers.py
-------------------------
Test factories that build the minimum object graph each scoring service
needs: a Course + Tee with realistic stroke indices, a Round, a
Foursome with N memberships, and helper functions to drop HoleScore
rows in.

The goal is one function per concept so individual tests stay short
and read like a scenario: "set up 4 players, score these holes, assert
the summary."
"""
from __future__ import annotations

from decimal import Decimal

from core.models import Course, Player, PlayerSex, Tee
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round


# ---------------------------------------------------------------------------
# Course / Tee
# ---------------------------------------------------------------------------

# Default per-hole layout for an 18-hole par-72 course.  Hole 1 is SI 7
# so stroke order isn't trivially "hole N = SI N" — that catches bugs
# where code accidentally uses hole_number as stroke_index.
DEFAULT_HOLES = [
    {'number':  1, 'par': 4, 'stroke_index':  7, 'yards': 400},
    {'number':  2, 'par': 4, 'stroke_index':  3, 'yards': 410},
    {'number':  3, 'par': 3, 'stroke_index': 15, 'yards': 175},
    {'number':  4, 'par': 5, 'stroke_index':  9, 'yards': 520},
    {'number':  5, 'par': 4, 'stroke_index':  1, 'yards': 440},
    {'number':  6, 'par': 4, 'stroke_index': 13, 'yards': 380},
    {'number':  7, 'par': 3, 'stroke_index': 17, 'yards': 165},
    {'number':  8, 'par': 5, 'stroke_index': 11, 'yards': 540},
    {'number':  9, 'par': 4, 'stroke_index':  5, 'yards': 420},
    {'number': 10, 'par': 4, 'stroke_index':  8, 'yards': 395},
    {'number': 11, 'par': 4, 'stroke_index':  4, 'yards': 415},
    {'number': 12, 'par': 3, 'stroke_index': 16, 'yards': 170},
    {'number': 13, 'par': 5, 'stroke_index': 10, 'yards': 530},
    {'number': 14, 'par': 4, 'stroke_index':  2, 'yards': 445},
    {'number': 15, 'par': 4, 'stroke_index': 14, 'yards': 385},
    {'number': 16, 'par': 3, 'stroke_index': 18, 'yards': 160},
    {'number': 17, 'par': 5, 'stroke_index': 12, 'yards': 535},
    {'number': 18, 'par': 4, 'stroke_index':  6, 'yards': 425},
]


def make_course(name: str = 'Test Links') -> Course:
    return Course.objects.create(name=name)


def make_tee(
    course: Course | None = None,
    *,
    tee_name: str = 'White',
    slope: int = 113,
    course_rating: float = 72.0,
    par: int = 72,
    holes: list | None = None,
) -> Tee:
    """slope=113 + rating=par means course_handicap == handicap_index — keeps
    test math obvious.  Override for tee-specific scenarios."""
    course = course or make_course()
    return Tee.objects.create(
        course        = course,
        tee_name      = tee_name,
        slope         = slope,
        course_rating = Decimal(str(course_rating)),
        par           = par,
        holes         = holes or DEFAULT_HOLES,
    )


# ---------------------------------------------------------------------------
# Player
# ---------------------------------------------------------------------------

def make_player(
    name: str,
    handicap_index: float | int = 0,
    *,
    sex: str = PlayerSex.MALE,
    short_name: str = '',
    is_phantom: bool = False,
) -> Player:
    return Player.objects.create(
        name           = name,
        handicap_index = Decimal(str(handicap_index)),
        sex            = sex,
        short_name     = short_name,
        is_phantom     = is_phantom,
    )


# ---------------------------------------------------------------------------
# Round / Foursome / Membership
# ---------------------------------------------------------------------------

def make_round(
    course: Course | None = None,
    *,
    handicap_mode: str = 'net',
    net_percent: int = 100,
    net_max_double_bogey: bool = True,
    status: str = 'in_progress',
    active_games: list | None = None,
) -> Round:
    course = course or make_course()
    return Round.objects.create(
        course               = course,
        status               = status,
        active_games         = active_games or [],
        handicap_mode        = handicap_mode,
        net_percent          = net_percent,
        net_max_double_bogey = net_max_double_bogey,
    )


def make_foursome(
    round_obj: Round,
    players_with_hcp: list[tuple[Player | str, int | float]],
    *,
    tee: Tee | None = None,
    group_number: int = 1,
) -> Foursome:
    """
    Build a foursome and its memberships from a list of
    (player_or_name, playing_handicap) tuples.  The first arg may be an
    existing Player or a bare name — bare names create a fresh Player
    with that handicap_index.

    playing_handicap is what the games actually read for stroke
    allocation, so we set it directly rather than computing through
    Player.course_handicap.  Tests that need realistic playing_handicap
    derivation can pass a Player created with a specific handicap_index
    and a non-trivial tee.
    """
    tee = tee or make_tee()
    fs  = Foursome.objects.create(round=round_obj, group_number=group_number)
    for p, hcp in players_with_hcp:
        player = p if isinstance(p, Player) else make_player(p, handicap_index=hcp)
        FoursomeMembership.objects.create(
            foursome         = fs,
            player           = player,
            tee              = tee,
            course_handicap  = int(hcp),
            playing_handicap = int(hcp),
        )
    return fs


# ---------------------------------------------------------------------------
# HoleScore — direct DB insert, matching what ScoreSubmitView does
# ---------------------------------------------------------------------------

def submit_hole(
    foursome: Foursome,
    hole_number: int,
    scores: list[tuple[int | Player, int]],
) -> None:
    """
    Persist the given per-player gross scores for `hole_number`.  Each
    entry is (player_or_id, gross_score).  handicap_strokes is set to
    what FoursomeMembership.handicap_strokes_on_hole would compute, so
    the resulting HoleScore matches what the real score-submit view
    produces.
    """
    memberships = {
        m.player_id: m for m in foursome.memberships.select_related('tee').all()
    }
    for entry in scores:
        player_or_id, gross = entry
        pid = player_or_id.id if isinstance(player_or_id, Player) else player_or_id
        m   = memberships[pid]
        si  = m.tee.hole(hole_number).get('stroke_index', 18)
        hcp_strokes = m.handicap_strokes_on_hole(si)
        hs, _ = HoleScore.objects.get_or_create(
            foursome    = foursome,
            player_id   = pid,
            hole_number = hole_number,
            defaults    = {'handicap_strokes': hcp_strokes},
        )
        hs.gross_score      = gross
        hs.handicap_strokes = hcp_strokes
        hs.save()


def submit_round(
    foursome: Foursome,
    scores_by_hole: dict[int, list[tuple[int | Player, int]]],
) -> None:
    """Convenience for tests that drop in a full round at once."""
    for hole, scores in scores_by_hole.items():
        submit_hole(foursome, hole, scores)
