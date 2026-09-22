"""
services/better_ball.py
-----------------------
Better Ball — best N of four, fixed for all eighteen holes.

**One control, and everything else on the screen is a read-back.** The count is
the game: a group of four plays its own balls, the N lowest nets count on every
hole, and the group's total is ranked against the whole field
(`handoff-foursome-formats/HANDOFF.md` §1).

## Why it is not a variant of Irish Rumble

Rumble's count MOVES as the round goes on, and that movement is what the group
plays around — one ball early, all four on the closer. Better Ball's is chosen
once and never changes, so the group knows on the first tee exactly how many
balls it needs all day. That is a different game a golfer plays differently,
not a setting inside another one, which is why it is its own entry in the game
list with its own setup.

What it DOES share is the engine and the money, and those are shared rather
than copied: the per-hole best-N walk, the live board, the tie rule and the
group-pool split all live in `services.group_field`, with the ball count passed
in. Rumble derives that count from its segments; Better Ball repeats one number
eighteen times.

## The three rules this module owns

**The name follows the count until the TD types.** 1 ball is `Better Ball`, the
common club format; 2 is `Best 2 of 4`; 3 is `Best 3 of 4`; and 4 is
`Aggregate`, which is a different game in character — every net counts on every
hole, so no golfer can drop a bad one. Once the TD names it himself the app
stops renaming it, because a name somebody chose should not move when he
changes his mind about the count.

**The allowance default follows the count.** Off the published table
(`services.team_handicap.SHAMBLE_PCT_BY_BALLS`): 1 -> 75%, 2 -> 85%, 3 -> 95%,
4 -> 100%. The fewer balls count, the more one low golfer's ball carries the
group, which is what the allowance is correcting for. It is a DEFAULT — the TD
owns the number and the app stops suggesting once he moves it (Paul, 22 Sep
2026). Set here rather than inherited, because Better Ball is the main game and
the allowance is a property of the format.

**The net double-bogey cap is always on.** It is a rule of individual play, not
a round setting, and it is applied BEFORE the best nets are picked — which is
the whole of what makes it a damage limiter rather than a scoring tweak. That
is the same call `low_net_round` makes with `force_cap`.
"""
from django.db import transaction

from core.models import HandicapMode
from games.models import BetterBallConfig


class BetterBallExcluded(Exception):
    """Better Ball and Irish Rumble are the same competition scored two ways.

    **One round runs one of them.** They rank the same groups off the same
    cards into the same kind of pool, so a round carrying both would take two
    entry fees for one competition and print two boards a golfer has no way to
    tell apart — and the only thing separating them on screen is a number he
    cannot see moving.

    Guarded in the SERVICE rather than the wizard, so every caller is covered:
    the setup endpoint, the cup round's auto-create, and whatever adds one
    next. The refusal names the game already there, because the fix is to turn
    that one off and the TD should not have to go looking for it.
    """


def _refuse_if_rumble(round_obj) -> None:
    from games.models import IrishRumbleConfig
    if IrishRumbleConfig.objects.filter(round=round_obj).exists():
        raise BetterBallExcluded(
            'This round is already running Irish Rumble. Better Ball ranks '
            'the same groups the same way, so a round runs one or the other '
            '— turn Irish Rumble off first.')


# 4 is worth its own word. `Best 4 of 4` describes the arithmetic and misses
# the point: when every net counts on every hole, nobody can have a bad hole
# quietly, and the group plays the round differently because of it.
_NAMES = {
    1: 'Better Ball',
    2: 'Best 2 of 4',
    3: 'Best 3 of 4',
    4: 'Aggregate',
}


def default_name(balls: int) -> str:
    """The title the app gives the game at this count.

    Mirrored in `mobile/lib/utils/better_ball.dart` — the setup screen has to
    rename the field live as the stepper moves, and a round trip per tap is
    not a thing to build for four strings.
    """
    return _NAMES.get(int(balls or 0), _NAMES[2])


def default_allowance(balls: int) -> int:
    """The suggested allowance at this count, off the published table.

    **A suggestion, not a rule.** The TD's number wins the moment he sets one;
    this is only what the stepper offers while he has not.
    """
    from services.team_handicap import DEFAULT_SHAMBLE_PCT, SHAMBLE_PCT_BY_BALLS
    return SHAMBLE_PCT_BY_BALLS.get(int(balls or 0), DEFAULT_SHAMBLE_PCT)


@transaction.atomic
def setup_better_ball(round_obj, *, balls_to_count=2, name='',
                      handicap_mode=HandicapMode.NET, net_percent=None,
                      entry_fee=0, payouts=None) -> BetterBallConfig:
    """Create or update the round's Better Ball config.

    `net_percent=None` means "follow the count" and resolves off the published
    table; pass a number to pin it. `name=''` likewise means "follow the
    count", which is what the setup screen's `Auto` tag is showing.
    """
    _refuse_if_rumble(round_obj)
    # `is None` rather than `or`: 0 is a value the stepper can post and it
    # clamps to 1, where falling back to the default would silently give the
    # TD a different game from the one he was looking at.
    balls = 2 if balls_to_count is None else max(1, min(4, int(balls_to_count)))
    config, _ = BetterBallConfig.objects.update_or_create(
        round=round_obj,
        defaults={
            'balls_to_count': balls,
            'name'          : (name or '').strip(),
            'handicap_mode' : handicap_mode,
            'net_percent'   : (default_allowance(balls) if net_percent is None
                               else int(net_percent)),
            'entry_fee'     : entry_fee or 0,
            'payouts'       : payouts or [],
        },
    )
    # The borrowed 4th is a property of the competition, not of Rumble — a
    # threesome in a field of foursomes counts a ball short on every hole
    # whichever of the two games is being played.
    ensure_better_ball_phantom(round_obj)
    return config


def ensure_better_ball_phantom(round_obj) -> int:
    """Level every true threesome with a borrowed 4th. No-op without a config.

    Delegates to Rumble's implementation, which is the same machinery and was
    written first: a fixed, shuffled donor rotation over every real golfer in
    every other group.
    """
    if not BetterBallConfig.objects.filter(round=round_obj).exists():
        return 0
    from services.irish_rumble import _ensure_borrowed_fourth
    return _ensure_borrowed_fourth(round_obj)


@transaction.atomic
def calculate_better_ball(round_obj) -> None:
    """Recalculation hook.

    **Nothing is persisted, and that is deliberate.** Rumble stores a row per
    group per SEGMENT because it has several and the per-segment board is a
    thing people read; Better Ball has exactly one segment, so a stored row
    would carry the same number the overall board already computes live. What
    this does own is the borrowed 4th, which has to keep up with a group that
    changes size mid-round — the same reason Rumble re-runs it here rather
    than only at setup.
    """
    ensure_better_ball_phantom(round_obj)


def better_ball_summary(round_obj) -> dict:
    """The board, the money and the one line of read-back."""
    from services.irish_rumble import _build_ir_score_index, _par_index_for_round
    from services.group_field import field_pool, group_standings

    try:
        config = round_obj.better_ball_config
    except BetterBallConfig.DoesNotExist:
        return {'configured': False, 'overall': []}

    balls = config.balls_to_count
    # **The cap is forced.** `_build_ir_score_index` reads the round's own
    # `net_max_double_bogey` flag for Rumble, where it is opt-in; in individual
    # play it is a rule, so it does not ask.
    score_index = _build_ir_score_index(
        round_obj, config.handicap_mode, config.net_percent, force_cap=True)
    par_by_hole = _par_index_for_round(round_obj)

    overall = group_standings(
        round_obj,
        balls_by_hole = {h: balls for h in range(1, 19)},
        score_index   = score_index,
        par_by_hole   = par_by_hole,
        entry_fee     = config.entry_fee,
        payouts       = config.payouts or [],
        net_percent   = config.net_percent,
    )

    return {
        'configured'    : True,
        'name'          : config.display_name(),
        'name_is_auto'  : not config.name,
        'balls_to_count': balls,
        'handicap_mode' : config.handicap_mode,
        'net_percent'   : config.net_percent,
        # What the TD would be offered at this count if he had not set one —
        # the readback says "Set by you, N% instead of the recommended M%"
        # and needs both numbers to say it.
        'recommended_net_percent': default_allowance(balls),
        'entry_fee'     : float(config.entry_fee),
        'payouts'       : config.payouts or [],
        'pool'          : field_pool(round_obj, config.entry_fee),
        # One line, not eighteen. The count cannot change mid-round, so the
        # preview is a statement rather than a grid.
        'segment_preview': (
            'Every net counts — nothing dropped' if balls >= 4
            else f'Holes 1–18 · Best {balls} '
                 f'{"net" if balls == 1 else "nets"} per group'),
        'overall'       : overall,
    }
