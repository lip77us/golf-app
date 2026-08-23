"""
services/team_handicap.py
-------------------------
Team Play allowance maths — the step that decides whether anyone believes the
result (docs/design-review/handoff-team-play/SPEC.md §6).

**The allowance is a table, not a preference.**  Each format has an established
allowance; the screen states it, shows it applied to the TD's OWN teams, and
offers one flat override for a group with its own tradition.  Presenting a
table as an open question invites a guess.

    Scramble   25 / 20 / 15 / 10 of course handicap, LOWEST FIRST, summed
               → one whole-number team figure.
    Shamble    a single percentage of each golfer's OWN course handicap,
               tracking the ball-count average — 75% at one ball, 85% at two,
               95% at three.

Three rules govern the arithmetic, and the first is the one that costs a stroke
when it is got wrong:

1. **Round once, on the total.**  Rounding each contribution first turns
   1.00 + 1.60 + 1.65 + 1.90 into 1 + 2 + 2 + 2 = 7.  Rounding the sum gives 6.
   Compute at full precision throughout and round at the end.
2. **Half rounds up.**  7.50 → 8.  (Python's built-in ``round`` is half-to-EVEN
   and would give 8 here but 6 for 6.50, so every rounding in this module goes
   through ``Decimal`` with ``ROUND_HALF_UP``.)
3. **Whole strokes, never fractions.**  Golfers do not play 6.15, and it looks
   like a spreadsheet error at the scoring table.  Which makes ties normal —
   see the payout rules, which combine and split rather than break them.

Everything here is pure: course handicaps in, figures out, no DB access.  The
worked examples in the packet are the test cases.

    Pine   4, 8, 11, 19  → 1.00 1.60 1.65 1.90 → raw 6.15 → 6
    Clay   6, 9, 14, 21  → 1.50 1.80 2.10 2.10 → raw 7.50 → 8   (half up)
    Slate  5, 12, 16, 24 → 1.25 2.40 2.40 2.40 → raw 8.45 → 8
    Dune   9, 15, 23 + phantom 16
                         → 2.25 3.00 2.40 2.30 → raw 9.95 → 10
"""

from dataclasses import dataclass, field
from decimal import Decimal, ROUND_HALF_UP


# The scramble table, lowest handicap first.  The order IS the rule: 25%
# attaches to the lowest handicap, not to the captain or the first name on the
# list, which is why every screen sorts members low to high.
SCRAMBLE_TABLE = (Decimal('0.25'), Decimal('0.20'), Decimal('0.15'), Decimal('0.10'))


# ---------------------------------------------------------------------------
# Pairs — five formats, and the allowance is doing enormous work
# ---------------------------------------------------------------------------
#
# The finding worth acting on (docs/design-review/handoff-team-pairs/SPEC.md
# §4).  The SAME pair — Maiolini 4, Yau 19 — plays off:
#
#     Scramble        35% low + 15% high      1.40 + 2.85 = 4.25  →   4
#     Best ball       85% of each, own ball   3.40 / 16.15    →   3 / 16
#     Alternate shot  50% of combined         23 × 0.50 = 11.50   →  12
#     Scotch          60% low + 40% high      2.40 + 7.60 = 10.00 →  10
#     Chapman         60% low + 40% high                          →  10
#
# Three times the strokes from the format alone, which is why the format screen
# shows the pair's figure on EVERY option before it is chosen.
#
# Four of the five end in one ball and are positional tables — lowest first,
# summed, rounded once — which is the arithmetic `scramble_allowance` already
# does.  50% of combined is 50% low + 50% high, so alternate shot is a table
# like the rest and needs no special case.
#
# **Scotch and Chapman share a table.**  Both are two drives then one ball;
# Chapman buys one extra shot of position, which is not worth a stroke.  The
# honest answer, rather than a manufactured difference.
PAIRS_TABLES = {
    'scramble'      : (Decimal('0.35'), Decimal('0.15')),
    'alternate_shot': (Decimal('0.50'), Decimal('0.50')),
    'scotch'        : (Decimal('0.60'), Decimal('0.40')),
    'chapman'       : (Decimal('0.60'), Decimal('0.40')),
}

# Best ball is the ONLY pairs format whose allowance is per golfer: each golfer
# plays their own strokes and the better net counts.  Not a team figure at all —
# the summed number exists solely as a balance figure for the strip, the same
# way the shamble's does.
BEST_BALL_PCT = 85


def allowance_table(team_size: int, team_format: str):
    """
    The positional table for a one-ball format, or ``None`` when the format
    handicaps each golfer on their own ball.

    Keyed on **(size, format)** and never on the format alone: `scramble` is
    the one format both sizes run and its table is not shared — four golfers take
    25/20/15/10 and two take 35/15.
    """
    if int(team_size) == 2:
        return PAIRS_TABLES.get(team_format)
    return SCRAMBLE_TABLE if team_format == 'scramble' else None

# Shamble: the allowance follows how many balls count.  The fewer balls, the
# lower the percentage.
SHAMBLE_PCT_BY_BALLS = {1: 75, 2: 85, 3: 95, 4: 100}

# Build-time call: the packet gives 75 / 85 / 95 for one, two and three balls
# and says a per-hole grid averaging 2.3 gets 95% "rather than 85%" — so the
# mapping is a CEILING, not a round-to-nearest.  A round that ever asks for
# three balls is a three-ball round for allowance purposes.  Four balls counts
# everybody, so it takes the full handicap; the packet does not state that case
# because a whole round at four balls has no drop score at all.
DEFAULT_SHAMBLE_PCT = 85


def _round_half_up(value: Decimal) -> int:
    """Whole strokes, half up. Clay's 7.50 becomes 8."""
    return int(Decimal(value).quantize(Decimal('1'), rounding=ROUND_HALF_UP))


def _contribution(course_handicap: int, pct: int) -> Decimal:
    """
    One golfer's strokes at their percentage, to two places — `Maiolini 4 → 1.00`,
    the way the worked card draws it.

    Two places is EXACT here, not a rounding: an integer course handicap times
    an integer percentage over 100 can never need a third.  So the sum of the
    contributions is still full precision, and rule 1 (round once, on the
    total) is untouched.
    """
    return ((Decimal(course_handicap) * Decimal(pct)) / Decimal(100)).quantize(
        Decimal('0.01')
    )


@dataclass
class Contribution:
    """One member's line on the worked card: `Maiolini 4 → 1.00`."""
    course_handicap: int
    pct: int                       # 25 / 20 / 15 / 10, or the flat override
    strokes: Decimal               # full precision — never rounded here
    is_phantom: bool = False


@dataclass
class TeamAllowance:
    """
    The two numbers a TD needs: the one they play with, and the one that
    explains it.  ``raw`` is shown under ``strokes`` on every screen that shows
    a team figure.
    """
    strokes: int                             # the rounded, whole-stroke figure
    raw: Decimal                             # the full-precision sum
    contributions: list = field(default_factory=list)


def phantom_course_handicap(real_course_handicaps) -> int:
    """
    A team of three fields a phantom 4th at the AVERAGE of its three real golfers.
    Bellini 9, Kwan 15, Ortega 23 → 16.

    This keeps everything downstream identical: four handicaps, so the ordinary
    table applies with no special three-golfer row, and four balls, so the format
    is unchanged.

    The alternative — dropping the table's bottom row and giving the three golfers
    25/20/15 — produces 9 against the phantom's 10, and a 30/20/10 table gives
    8.  Both take a stroke AWAY from a team that is already short a ball, which
    is backwards.  **The allowance follows the roster, not the number of balls
    hit**, which is also why "play short" carries the same figure: the only
    thing it changes is whether anybody hits the phantom's ball.
    """
    hcaps = list(real_course_handicaps)
    if not hcaps:
        return 0
    return _round_half_up(Decimal(sum(hcaps)) / Decimal(len(hcaps)))


def positional_allowance(course_handicaps, table, *, override_pct=None,
                         phantom_index=None) -> TeamAllowance:
    """
    One team figure built from a POSITIONAL percentage table — the arithmetic
    behind every format that ends in one ball.

    ``table`` is the percentages in table order, lowest handicap first:
    ``SCRAMBLE_TABLE`` for four golfers, one of ``PAIRS_TABLES`` for two.

    ``course_handicaps`` need not be sorted — this sorts them low to high,
    because the percentage is POSITIONAL and a manual order would be a lie.
    Pass ``phantom_index`` as the position of the phantom's handicap in the
    ORIGINAL list and it is tracked through the sort, so the caller can draw
    the phantom's row italic wherever it lands.

    ``override_pct`` applies one flat percentage to every golfer — a group's
    tradition beats the table — and the worked result is still returned so the
    TD sees what they did.
    """
    indexed = sorted(
        ((h, i) for i, h in enumerate(course_handicaps)), key=lambda p: p[0]
    )

    contributions = []
    for position, (hcap, original_index) in enumerate(indexed):
        if override_pct is not None:
            pct = int(override_pct)
        elif position < len(table):
            pct = int(table[position] * 100)
        else:
            # More golfers than the table has rows is not a shape this tournament
            # builds, but an extra one must not silently repeat the last
            # percentage.  (A three-golfer best-ball pair never reaches here —
            # best ball handicaps each golfer on their own ball.)
            pct = 0
        contributions.append(Contribution(
            course_handicap = hcap,
            pct             = pct,
            strokes         = _contribution(hcap, pct),
            is_phantom      = (original_index == phantom_index),
        ))

    raw = sum((c.strokes for c in contributions), Decimal('0'))
    return TeamAllowance(
        strokes       = _round_half_up(raw),
        raw           = raw,
        contributions = contributions,
    )


def scramble_allowance(course_handicaps, *, override_pct=None,
                       phantom_index=None) -> TeamAllowance:
    """The four-golfer scramble: 25 / 20 / 15 / 10, lowest first, summed."""
    return positional_allowance(
        course_handicaps, SCRAMBLE_TABLE,
        override_pct=override_pct, phantom_index=phantom_index,
    )


def shamble_allowance_pct(avg_ball_count) -> int:
    """
    The percentage a shamble applies to each golfer's OWN course handicap,
    tracking the ball-count average.

    A ceiling, not a round-to-nearest: a per-hole grid averaging 2.3 asks for
    three balls somewhere, so it takes 95% rather than 85%.
    """
    avg = Decimal(str(avg_ball_count))
    if avg <= 0:
        return DEFAULT_SHAMBLE_PCT
    balls = int(avg.quantize(Decimal('1'), rounding='ROUND_CEILING'))
    return SHAMBLE_PCT_BY_BALLS.get(min(max(balls, 1), 4), DEFAULT_SHAMBLE_PCT)


def shamble_allowance(course_handicaps, *, avg_ball_count=2,
                      override_pct=None, phantom_index=None) -> TeamAllowance:
    """
    A shamble handicaps each golfer on their own ball, so there is no single team
    figure in play — the per-golfer strokes are what the card uses.

    The ``strokes`` returned here is therefore a BALANCE figure only: the sum of
    the four allowances, rounded once, used by the build-teams strip so a TD can
    see one team stacked against another. It is never subtracted from anything.
    """
    pct = int(override_pct) if override_pct is not None \
        else shamble_allowance_pct(avg_ball_count)

    contributions = [
        Contribution(
            course_handicap = hcap,
            pct             = pct,
            strokes         = _contribution(hcap, pct),
            is_phantom      = (i == phantom_index),
        )
        for i, hcap in enumerate(sorted(course_handicaps))
    ]
    raw = sum((c.strokes for c in contributions), Decimal('0'))
    return TeamAllowance(
        strokes       = _round_half_up(raw),
        raw           = raw,
        contributions = contributions,
    )


def best_ball_allowance(course_handicaps, *, override_pct=None) -> TeamAllowance:
    """
    Best ball — **85% of each golfer's own course handicap**, their own ball, the
    better net counting.

    The only pairs format whose allowance is per golfer, and the only one
    entering two scores.  Maiolini 4 → 3, Yau 19 → 16; the card reads
    ``3 / 16`` rather than one figure.

    Like the shamble's, the ``strokes`` returned here is a BALANCE figure only
    — the sum of the two allowances, rounded once, so the strip can stack one
    pair against another.  It is never subtracted from anything.

    A three-golfer best-ball pair (the odd-field way out) works unchanged: each of
    the three takes 85% of their own.
    """
    pct = int(override_pct) if override_pct is not None else BEST_BALL_PCT
    contributions = [
        Contribution(
            course_handicap = hcap,
            pct             = pct,
            strokes         = _contribution(hcap, pct),
        )
        for hcap in sorted(course_handicaps)
    ]
    raw = sum((c.strokes for c in contributions), Decimal('0'))
    return TeamAllowance(
        strokes       = _round_half_up(raw),
        raw           = raw,
        contributions = contributions,
    )


def player_own_ball_handicap(course_handicap: int, pct: int) -> int:
    """
    One golfer's playing handicap when they play their own ball — their own course
    handicap at the format's percentage, rounded to whole strokes.  Shamble and
    best ball alike.

    Rounded PER GOLFER here, unlike the one-ball formats, and for the same
    reason: this is the number they play with on their own ball, so it is their
    figure that has to be whole rather than a team total's.
    """
    return _round_half_up(_contribution(course_handicap, pct))


# The name this had while a shamble was the only own-ball format.
player_shamble_handicap = player_own_ball_handicap
