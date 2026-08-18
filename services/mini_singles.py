"""
services/mini_singles.py
------------------------
The **Mini Singles Bracket** — the tournament-level, two-stage layer over the
per-foursome brackets in services/tournament_match_play.py.
See docs/design-review/handoff-individual-play/SPEC.md §4.

    Day 1   a bracket in EVERY group. Two semis on the front, final and 3rd
            place together on the back. Each group produces a champion.
    Day 2   the group champions play as ONE foursome — semis, then the final
            and a 3rd-place match. One champion.
    Everyone else plays day 2 as a normal stroke-play round.

Which is exactly why it is a side game and not the championship: run it as the
main event and three quarters of the field is out of contention on Saturday.

What the TD sets, and what is derived
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Day-1 seeds are seeded by index and draggable per group. **The day-2 foursome
is not set at all** — the TD cannot know the four winners when he builds
Sunday's tee times, so the groups step RESERVES a foursome
(``Foursome.is_champions_foursome``) and ``sync_day2_champions`` swaps the
winners into it. Everyone displaced takes the seat a winner vacated, so tees
and tee times survive the swap.

Day-2 seeding is **not index again** — it is day-1 MARGIN, so the man who won
5&4 takes seed 1 and meets the narrowest winner. Lowest index breaks a tie,
which it will: two 2&1 winners is an ordinary Saturday.

Public API
~~~~~~~~~~
    ok, groups, reason = check_field(n_golfers)
    winners            = derive_day2_field(tournament)
    foursome           = sync_day2_champions(tournament)
    summary            = mini_singles_summary(tournament)
"""
from django.db import transaction

from games.models import MatchPlayBracket, MiniSinglesConfig
from services.payout import carve_out, payouts_by_place, split_tied_places
from tournament.models import Foursome, FoursomeMembership


# ---------------------------------------------------------------------------
# The field has to fit 16
# ---------------------------------------------------------------------------

FIELD_MIN = 9
FIELD_MAX = 16


def check_field(n_golfers: int) -> tuple:
    """
    Return ``(ok, group_count, reason)`` for a field size.

    Group count is what the game actually runs on, and four is the ceiling:

    ==========  ======  =================================================
    Golfers     Groups  Shape
    ==========  ======  =================================================
    up to 8     2       A final with no semis. Not a bracket; not offered.
    9–12        3       Full bracket day 1; day 2 takes the empty-seat rule.
    13–16       4       The full bracket, both days identical in shape.
    over 16     5+      Five winners cannot play a knockout in one round —
                        it needs a third day, so it is not offered on a
                        two-day tournament rather than being faked with a
                        play-in.
    ==========  ======  =================================================
    """
    if n_golfers < FIELD_MIN:
        return False, 0, (
            f'{n_golfers} golfers is too few for Mini Singles. Eight or fewer '
            f'gives a final with no semis, which is not a bracket — it needs '
            f'at least {FIELD_MIN}.'
        )
    if n_golfers > FIELD_MAX:
        return False, 0, (
            f'{n_golfers} golfers is too many for Mini Singles. Above '
            f'{FIELD_MAX} you get five group winners, and five cannot play a '
            f'knockout in one round — it needs a third day.'
        )
    groups = 4 if n_golfers >= 13 else 3
    return True, groups, ''


# ---------------------------------------------------------------------------
# Day 1 → day 2
# ---------------------------------------------------------------------------

def _day1_round(tournament):
    return tournament.rounds.order_by('round_number').first()


def _day2_round(tournament):
    return tournament.rounds.order_by('-round_number').first()


def _final_margin(bracket) -> int:
    """
    The margin the group champion won his final by — 5&4 is a margin of 5.
    Zero for a halved final, where the trophy came off the last hole won and
    there is no margin to read.
    """
    final = (bracket.matches.filter(round_number=2)
             .order_by('id').first())
    if final is None or final.result == 'halved':
        return 0
    last = final.hole_results.order_by('-hole_number').first()
    return abs(last.holes_up_after) if last else 0


def _beaten_finalists(tournament, exclude_ids):
    """
    Every golfer who lost a day-1 FINAL, best net over the day-1 round first.

    This is the promotion pool: "the lowest net of the three beaten finalists
    fills the fourth seat — and still has to win two matches to take it".
    """
    from services.low_net_round import _build_ln_player_totals

    day1 = _day1_round(tournament)
    if day1 is None:
        return []

    losers = []
    for fs in day1.foursomes.all():
        bracket = MatchPlayBracket.objects.filter(foursome=fs).first()
        if bracket is None:
            continue
        final = bracket.matches.filter(round_number=2).order_by('id').first()
        if final is None or final.status != 'complete':
            continue
        if final.result == 'player1':
            losers.append(final.player2)
        elif final.result == 'player2':
            losers.append(final.player1)
        elif final.trophy_player_id:
            # Halved: the trophy took the seat, so the other one is the
            # beaten finalist.
            losers.append(final.player2 if final.trophy_player_id == final.player1_id
                          else final.player1)

    losers = [p for p in losers if p.id not in exclude_ids]
    if not losers:
        return []

    nets = _build_ln_player_totals(
        day1, tournament.handicap_mode, tournament.net_percent,
        force_cap=tournament.is_individual_play)

    def _net_key(player):
        row = nets.get(player.id)
        if not row or not row['holes_played']:
            return (1, 0)                    # unscored sorts last
        return (0, row['total'] - row['par_played'])

    return sorted(losers, key=_net_key)


def derive_day2_field(tournament) -> list:
    """
    The champions' foursome, seeded — never set by the TD.

    Returns a list of dicts in SEED ORDER::

        [{'player': Player, 'margin': int, 'index': Decimal,
          'group_number': int, 'promoted': bool}, …]

    Seeded by **widest day-1 margin, then lowest index**. Not index again: the
    man who won 5&4 gets seed 1 and meets the narrowest winner.

    Short of four winners — three groups, or a withdrawal — the tournament's
    single ``empty_seat_rule`` applies, answered once at setup:

    * ``promote``  the lowest net beaten finalist fills the seat. He is not
                   being handed anything; he still has to win two matches.
    * ``points``   all three play points over the front, the two leaders play
                   the back nine as a match (services/three_person_match.py).
    * ``short``    nobody is refilled. No byes — a seat nobody earned is not
                   handed out as a free pass to the final.
    """
    day1 = _day1_round(tournament)
    if day1 is None:
        return []

    config = getattr(tournament, 'mini_singles_config', None)
    rule = config.empty_seat_rule if config else 'promote'

    winners = []
    for fs in day1.foursomes.order_by('group_number'):
        bracket = (MatchPlayBracket.objects
                   .filter(foursome=fs)
                   .prefetch_related('matches__hole_results')
                   .first())
        if bracket is None or bracket.winner_id is None:
            continue
        membership = FoursomeMembership.objects.filter(
            foursome=fs, player_id=bracket.winner_id).first()
        winners.append({
            'player'      : bracket.winner,
            'margin'      : _final_margin(bracket),
            'index'       : (membership.playing_handicap if membership else 0),
            'group_number': fs.group_number,
            'promoted'    : False,
        })

    if len(winners) < 4 and rule == 'promote':
        taken = {w['player'].id for w in winners}
        for player in _beaten_finalists(tournament, taken):
            if len(winners) >= 4:
                break
            membership = FoursomeMembership.objects.filter(
                foursome__round=day1, player=player).first()
            winners.append({
                'player'      : player,
                # A promoted golfer did not win a final, so he has no margin
                # and seeds last among equals — behind every group winner.
                'margin'      : -1,
                'index'       : (membership.playing_handicap if membership else 0),
                'group_number': (membership.foursome.group_number
                                 if membership else None),
                'promoted'    : True,
            })

    # Widest margin first, then lowest index.
    winners.sort(key=lambda w: (-w['margin'], w['index']))
    return winners


@transaction.atomic
def sync_day2_champions(tournament) -> Foursome | None:
    """
    Move the derived champions into the reserved day-2 foursome and (re)build
    its bracket, seeded by day-1 margin.

    The swap is by ``FoursomeMembership.foursome_id`` rather than by rebuilding
    memberships, so each golfer keeps the tee, handicaps and phantom config the
    round setup gave him — and every displaced golfer lands in the seat a
    champion vacated, which keeps the TD's group sizes and tee times intact.

    Returns the champions' foursome, or None when the tournament has no
    Mini Singles config, no reserved foursome, or no day-1 winners yet.
    """
    if getattr(tournament, 'mini_singles_config', None) is None:
        return None

    day2 = _day2_round(tournament)
    day1 = _day1_round(tournament)
    if day2 is None or day1 is None or day2.pk == day1.pk:
        return None

    reserved = day2.foursomes.filter(is_champions_foursome=True).first()
    if reserved is None:
        return None

    field = derive_day2_field(tournament)
    if not field:
        return None

    champion_ids = [w['player'].id for w in field]
    seated = {m.player_id: m for m in reserved.memberships.all()}

    # Champions not yet in the reserved group, and the golfers they displace.
    incoming = [
        m for m in FoursomeMembership.objects
                     .filter(foursome__round=day2, player_id__in=champion_ids)
                     .exclude(foursome=reserved)
    ]
    displaced = [m for pid, m in seated.items() if pid not in set(champion_ids)]

    for champion_m, displaced_m in zip(incoming, displaced):
        origin = champion_m.foursome_id
        champion_m.foursome_id = reserved.id
        displaced_m.foursome_id = origin
        champion_m.save(update_fields=['foursome'])
        displaced_m.save(update_fields=['foursome'])

    # Any champion left over (the reserved group had nobody to displace) just
    # moves in — this is the short-field case, where the group runs 3 or 2.
    for champion_m in incoming[len(displaced):]:
        champion_m.foursome_id = reserved.id
        champion_m.save(update_fields=['foursome'])

    _build_day2_bracket(tournament, reserved, field)
    return reserved


def _build_day2_bracket(tournament, foursome, field) -> None:
    """Create the champions' bracket, seeded by day-1 margin then index."""
    from services.tournament_match_play import setup_tournament_match_play
    from services.three_person_match import setup_three_person_match

    config = tournament.mini_singles_config
    seed_order = [w['player'].id for w in field]

    if len(seed_order) == 3 and config.empty_seat_rule in ('points', 'short'):
        # Points over the front, the two leaders play a match on the back —
        # and a tie in the points round PLAYS ON rather than going to a
        # card-off, which is what three_person_match already does (it settles
        # 1st and 2nd on holes 10+ then back-calculates the match from the
        # 10th). Same mechanism as the halved match: the golf decides it.
        setup_three_person_match(
            foursome,
            handicap_mode=config.handicap_mode,
            net_percent=config.net_percent,
        )
        return

    setup_tournament_match_play(
        foursome,
        seed_order    = seed_order,
        handicap_mode = config.handicap_mode,
        net_percent   = config.net_percent,
    )


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def _championship_pool(tournament) -> float:
    """The championship pool the day-2 carve-out comes off the top of."""
    for attr in ('low_net_championship_config', 'stableford_championship_config'):
        config = getattr(tournament, attr, None)
        if config is not None:
            players = FoursomeMembership.objects.filter(
                foursome__round__tournament=tournament,
                player__is_phantom=False,
            ).values('player_id').distinct().count()
            return round(float(config.entry_fee) * players, 2)
    return 0.0


def mini_singles_summary(tournament) -> dict | None:
    """
    Both stages, the two pots, and what is still derived.

    Returns None when the tournament has no Mini Singles config — nothing
    downstream may assume the bracket exists.
    """
    config = getattr(tournament, 'mini_singles_config', None)
    if config is None:
        return None

    day1 = _day1_round(tournament)
    day2 = _day2_round(tournament)
    two_day = day1 is not None and day2 is not None and day1.pk != day2.pk

    n_golfers = FoursomeMembership.objects.filter(
        foursome__round=day1, player__is_phantom=False).count() if day1 else 0
    ok, group_count, field_reason = check_field(n_golfers)

    # ── Day 1: a bracket in every group ──────────────────────────────────
    from services.tournament_match_play import tournament_match_play_summary
    day1_groups = []
    if day1 is not None:
        for fs in day1.foursomes.order_by('group_number'):
            summary = tournament_match_play_summary(fs)
            if summary is None:
                continue
            summary['group_number'] = fs.group_number
            summary['group']        = fs.display_name
            day1_groups.append(summary)

    # ── Day 2: the champions' foursome, derived ──────────────────────────
    field = derive_day2_field(tournament) if two_day else []
    day2_summary = None
    if two_day:
        reserved = day2.foursomes.filter(is_champions_foursome=True).first()
        if reserved is not None:
            day2_summary = tournament_match_play_summary(reserved)
            if day2_summary is not None:
                day2_summary['group_number'] = reserved.group_number

    # ── Money: two pots, funded differently ──────────────────────────────
    day1_fee   = float(config.day1_entry_fee)
    per_group  = [
        {
            'group_number': g['group_number'],
            'pot'         : round(day1_fee * len(g.get('players', [])), 2),
            'players'     : len(g.get('players', [])),
        }
        for g in day1_groups
    ]
    champ_pool = _championship_pool(tournament)
    carved, remaining = carve_out(champ_pool, tournament.mini_singles_carve_pct)

    return {
        'configured'     : True,
        'handicap'       : {'mode': config.handicap_mode,
                            'net_percent': config.net_percent},
        'empty_seat_rule': config.empty_seat_rule,
        'field'          : {
            'golfers'    : n_golfers,
            'groups'     : group_count,
            'fits'       : ok,
            'reason'     : field_reason,
            'min'        : FIELD_MIN,
            'max'        : FIELD_MAX,
        },
        'day1'           : {
            'round_id'   : day1.id if day1 else None,
            'entry_fee'  : day1_fee,
            'payouts'    : config.day1_payouts or [],
            'pots'       : per_group,
            'groups'     : day1_groups,
        },
        'day2'           : {
            'round_id'   : day2.id if two_day else None,
            # Read-only here: the carve-out is set at tournament setup, and
            # this screen reports it rather than configuring it.
            'carve_pct'  : tournament.mini_singles_carve_pct,
            'championship_pool'   : champ_pool,
            'pot'                 : carved,
            'left_for_championship': remaining,
            'payouts'    : config.day2_payouts or [],
            'seeds'      : [
                {
                    'seed'        : i + 1,
                    'player_id'   : w['player'].id,
                    'name'        : w['player'].name,
                    'margin'      : w['margin'],
                    'group_number': w['group_number'],
                    'promoted'    : w['promoted'],
                }
                for i, w in enumerate(field)
            ],
            'seeded_by'  : 'Widest day 1 margin, then lowest index',
            'bracket'    : day2_summary,
        },
        # Sunday consequences the board and the day bet both read.
        'finalist_player_ids': [w['player'].id for w in field],
    }


def day2_finalist_ids(tournament) -> set:
    """
    The golfers playing the day-2 champions' match.

    They keep their other side games — the ball game and Irish Rumble run as
    normal — but are **out of the day-2 stroke bet**: they are playing a match,
    not posting a card against the field. Empty when the bracket is off.
    """
    if getattr(tournament, 'mini_singles_config', None) is None:
        return set()
    return {w['player'].id for w in derive_day2_field(tournament)}


def day1_group_payouts(tournament, foursome) -> dict:
    """
    ``{player_id: amount}`` for one day-1 group's bracket.

    Places pay GOLFERS here (not a foursome), and a halved match splits the
    two places it occupies rather than paying the last hole won.
    """
    config = getattr(tournament, 'mini_singles_config', None)
    if config is None:
        return {}
    from services.tournament_match_play import tournament_match_play_summary
    summary = tournament_match_play_summary(foursome)
    if summary is None:
        return {}

    places = payouts_by_place(config.day1_payouts)
    out = {}
    # Finishing order 1..4 straight off the resolved places; halved matches
    # come back as a split pair, which split_tied_places handles by giving
    # both golfers the same rank.
    ranks = {}
    for i, row in enumerate(summary['money']['payouts'], start=1):
        if row['player_id'] is None:
            continue
        ranks[row['player_id']] = (i - 1 if row['split'] and i % 2 == 0 else i)

    per_rank = split_tied_places(places, list(ranks.values()))
    for pid, rank in ranks.items():
        out[pid] = per_rank.get(rank, 0.0)
    return out
