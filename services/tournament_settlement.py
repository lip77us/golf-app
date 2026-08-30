"""
services/tournament_settlement.py
---------------------------------
Every money decision in the individual-play spec lands here
(docs/design-review/handoff-individual-play/SPEC.md §9).

Seven pots over two days, entries taken at signup and prizes that only
resolved when the last card came in — and what a golfer wants is **one
number**: does he pay or does he collect. So the row is the answer and the
card is the proof; open it and every line that produced the number is there,
each entry a debit, each prize a credit, each naming the game that caused it.

Scope
~~~~~
**Tournament-scope games only** — the five the TD set. Foursome side bets
(skins, Nassau, spots, rabbit, survivor, sixes) are settled inside the
foursome and never appear in these totals. The reason is ownership: the TD did
not set them, does not know the stakes and is not collecting for them. Folding
them in would make him responsible for money he never handled, and would make
a golfer's net number depend on a bet three of his playing partners agreed to
on the first tee. ``services/settlement.py`` is the CASUAL, round-scoped
settlement and is untouched by this.

Two things make the arithmetic less obvious than it sounds
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* **The carve-out.** Mini Singles day 2 takes its pot OUT OF the championship
  pool rather than charging an entry, so the championship shows $640 in and
  $640 out with $160 of that leaving for another game's table. It is modelled
  as an explicit transfer so both sides balance and the total still sums to
  zero.
* **Not everybody staked the same.** Six of sixteen are out of the day bet for
  two different reasons and neither pays into it, so they list six entries
  where the ten who can win it list seven.

The checks
~~~~~~~~~~
**By game** is the TD's check, not the golfer's: entries in, prizes out, and
the difference. A game that does not balance BLOCKS the whole settlement and
says WHICH ONE — the mistake is always in a payout table, and it is always
found faster by naming the game than by naming a dollar figure.

The day bet resolves last: it cannot settle until the championship does, so
Settle stays off until every round is closed.

And the footer is the one number that proves the screen: **collected minus
paid must be zero**. It is a closed system — the golfers fund it entirely — so
any other answer is an arithmetic bug, not a rounding preference.
"""
from collections import defaultdict

from core.models import RoundStatus
from services.payout import carve_out
from tournament.models import FoursomeMembership

# Rounding slack. Splits divide by three (a levelled group) and by two (a
# halved final), so a pot can land a cent out honestly. Anything wider than
# this is a payout table that does not add up.
CENT_SLACK = 0.05


def _real_player_ids(round_obj) -> list:
    return list(
        FoursomeMembership.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .values_list('player_id', flat=True)
    )


def _field(tournament) -> dict:
    """``{player_id: name}`` for every real golfer in the tournament."""
    rows = (FoursomeMembership.objects
            .filter(foursome__round__tournament=tournament,
                    player__is_phantom=False)
            .values_list('player_id', 'player__name')
            .distinct())
    return {pid: name for pid, name in rows}


class _Pot:
    """
    One tournament-scope pot: what went in, what came out, and whether it
    balances.

    ``transfer_in`` funds a pot from another game's pool rather than from
    entries (Mini Singles day 2); ``transfer_out`` is the matching debit on the
    pool it came from (the championship).
    """

    def __init__(self, key, label, round_number=None):
        self.key          = key
        self.label        = label
        self.round_number = round_number
        self.entries      = []       # {'player_id', 'amount'}
        self.prizes       = []       # {'player_id', 'amount', 'detail'}
        self.transfer_in  = 0.0
        self.transfer_out = 0.0

    def enter(self, player_ids, amount):
        if amount <= 0:
            return
        for pid in player_ids:
            self.entries.append({'player_id': pid, 'amount': round(amount, 2)})

    def pay(self, player_id, amount, detail=''):
        if not amount or player_id is None:
            return
        self.prizes.append({'player_id': player_id,
                            'amount': round(float(amount), 2),
                            'detail': detail})

    @property
    def entries_in(self):
        return round(sum(e['amount'] for e in self.entries) + self.transfer_in, 2)

    @property
    def prizes_out(self):
        return round(sum(p['amount'] for p in self.prizes) + self.transfer_out, 2)

    @property
    def difference(self):
        return round(self.entries_in - self.prizes_out, 2)

    @property
    def balanced(self):
        return abs(self.difference) <= CENT_SLACK

    def as_dict(self):
        return {
            'key'         : self.key,
            'label'       : self.label,
            'round_number': self.round_number,
            'entries_in'  : self.entries_in,
            'prizes_out'  : self.prizes_out,
            'difference'  : self.difference,
            'balanced'    : self.balanced,
            'transfer_in' : self.transfer_in,
            'transfer_out': self.transfer_out,
        }


# ---------------------------------------------------------------------------
# The pots
# ---------------------------------------------------------------------------

def _championship_pot(tournament, field_ids):
    """The 36-hole pot, with the Mini Singles carve-out leaving from the top."""
    method = tournament.scoring_method or 'stroke'
    if method == 'stableford':
        config = getattr(tournament, 'stableford_championship_config', None)
        from services.stableford_championship import (
            stableford_championship_standings as standings_fn)
        label = 'Stableford Championship'
    else:
        config = getattr(tournament, 'low_net_championship_config', None)
        from services.low_net_championship import (
            low_net_championship_standings as standings_fn)
        label = 'Championship'
    if config is None:
        return None, 0.0

    pot = _Pot('championship', label)
    fee = float(config.entry_fee)
    pot.enter(field_ids, fee)

    pool = round(fee * len(field_ids), 2)
    carved, _remaining = carve_out(pool, tournament.mini_singles_carve_pct)
    if carved and getattr(tournament, 'mini_singles_config', None) is not None:
        # Leaves for another game's table rather than being paid to a golfer.
        pot.transfer_out = carved

    for row in standings_fn(tournament):
        pot.pay(row['player_id'], row.get('payout'),
                detail=f"{_ordinal(row['rank'])} — {label}")
    return pot, carved


def _ordinal(n):
    return f"{n}{ {1: 'st', 2: 'nd', 3: 'rd'}.get(n, 'th') }".replace(' ', '')


def _group_game_pots(tournament):
    """
    Irish Rumble and the ball game — **re-drawn every round**, so each appears
    once per round, entered separately and won separately. A group that wins
    the ball on both days collects twice.

    Both pay a GROUP, and the place splits among its real golfers: the
    borrowed 4th is not a person and cannot be paid.
    """
    from services.irish_rumble import irish_rumble_summary
    from services.red_ball import red_ball_summary

    pots = []
    for round_obj in tournament.rounds.order_by('round_number'):
        players = _real_player_ids(round_obj)
        n = round_obj.round_number

        if getattr(round_obj, 'irish_rumble_config', None) is not None:
            summary = irish_rumble_summary(round_obj)
            pot = _Pot('irish_rumble', f'Irish Rumble · R{n}', n)
            pot.enter(players, float(summary.get('entry_fee') or 0))
            for row in summary.get('overall', []):
                share = row.get('per_person_payout') or 0
                if not share:
                    continue
                ways = row.get('split_ways') or row.get('n_real_players') or 1
                for m in _group_member_ids(round_obj, row['foursome_id']):
                    pot.pay(m, share,
                            detail=f"{_ordinal(row['rank'])} — {row['group']} "
                                   f"({ways} ways)")
            pots.append(pot)

        if getattr(round_obj, 'pink_ball_config', None) is not None:
            summary = red_ball_summary(round_obj)
            name = summary.get('game_name') or 'Ball game'
            pot = _Pot('pink_ball', f'{name} · R{n}', n)
            pot.enter(players, float(summary.get('entry_fee') or 0))
            for row in summary.get('results', []):
                share = row.get('per_person_payout') or 0
                if not share:
                    continue
                ways = row.get('split_ways') or 1
                fs_id = _foursome_id_for_group(round_obj, row['group_number'])
                for m in _group_member_ids(round_obj, fs_id):
                    pot.pay(m, share,
                            detail=f"{_ordinal(row['rank'])} — Group "
                                   f"{row['group_number']} ({ways} ways)")
            pots.append(pot)
    return pots


def _foursome_id_for_group(round_obj, group_number):
    fs = round_obj.foursomes.filter(group_number=group_number).first()
    return fs.id if fs else None


def _group_member_ids(round_obj, foursome_id):
    if foursome_id is None:
        return []
    return list(
        FoursomeMembership.objects
        .filter(foursome_id=foursome_id, player__is_phantom=False)
        .values_list('player_id', flat=True)
    )


def _mini_singles_pots(tournament, carved):
    """Day 1 — a side bet per group. Day 2 — funded by the carve-out."""
    config = getattr(tournament, 'mini_singles_config', None)
    if config is None:
        return []

    from services.mini_singles import _day1_round, _day2_round, day1_group_payouts
    from services.tournament_match_play import tournament_match_play_summary

    pots = []
    day1 = _day1_round(tournament)
    if day1 is not None:
        pot = _Pot('mini_singles_day1', 'Mini Singles · day 1',
                   day1.round_number)
        pot.enter(_real_player_ids(day1), float(config.day1_entry_fee))
        for fs in day1.foursomes.order_by('group_number'):
            for pid, amount in day1_group_payouts(tournament, fs).items():
                pot.pay(pid, amount,
                        detail=f'Mini Singles — {fs.display_name}')
        pots.append(pot)

    day2 = _day2_round(tournament)
    if day2 is not None and day1 is not None and day2.pk != day1.pk:
        pot = _Pot('mini_singles_day2', "Mini Singles · champions' foursome",
                   day2.round_number)
        # No entry: the pot IS the carve-out, which is why 4th has nothing to
        # refund.
        pot.transfer_in = carved
        reserved = day2.foursomes.filter(is_champions_foursome=True).first()
        if reserved is not None:
            summary = tournament_match_play_summary(reserved)
            if summary:
                from services.payout import payouts_by_place, split_tied_places
                places = payouts_by_place(config.day2_payouts)
                ranks = {}
                for i, row in enumerate(summary['money']['payouts'], start=1):
                    if row['player_id'] is None:
                        continue
                    ranks[row['player_id']] = (
                        i - 1 if row['split'] and i % 2 == 0 else i)
                per_rank = split_tied_places(places, list(ranks.values()))
                for pid, rank in ranks.items():
                    pot.pay(pid, per_rank.get(rank),
                            detail=f'{_ordinal(rank)} — Mini Singles')
        pots.append(pot)
    return pots


def _day_bet_pot(tournament):
    """
    Final round only. The ineligible do not pay in, so their entry is never
    collected rather than refunded — and the pot cannot settle until the
    championship does.
    """
    from games.models import DayBetConfig
    from services.day_bet import day_bet_standings

    config = (DayBetConfig.objects
              .filter(round__tournament=tournament)
              .select_related('round')
              .order_by('-round__round_number').first())
    if config is None:
        return None

    round_obj = config.round
    rows = day_bet_standings(round_obj)
    pot  = _Pot('day_bet', f'Day bet · R{round_obj.round_number}',
                round_obj.round_number)
    pot.enter([r['player_id'] for r in rows if r['eligible']],
              float(config.entry_fee))
    for row in rows:
        if row.get('payout'):
            pot.pay(row['player_id'], row['payout'],
                    detail=f"{_ordinal(row['rank'])} — day bet")
    return pot


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def tournament_settlement(tournament) -> dict:
    """
    One net number per golfer, itemised, plus the TD's by-game check.

    Returns::

        {
          'golfers'    : [{player_id, name, entries[], prizes[], net}, …],
          'games'      : [{key, label, entries_in, prizes_out, balanced, …}],
          'balanced'   : bool,          # every pot balances
          'blocking'   : [str, …],      # why Settle is off, named
          'can_settle' : bool,
          'total_collected', 'total_paid', 'sum_zero',
          'excluded_note': str,
        }
    """
    field = _field(tournament)
    field_ids = list(field.keys())

    champ, carved = _championship_pot(tournament, field_ids)
    pots = [p for p in [champ] if p is not None]
    pots += _mini_singles_pots(tournament, carved)
    pots += _group_game_pots(tournament)
    day_bet = _day_bet_pot(tournament)
    if day_bet is not None:
        pots.append(day_bet)

    # ── Per golfer ────────────────────────────────────────────────────────
    entries_by_pid = defaultdict(list)
    prizes_by_pid  = defaultdict(list)
    for pot in pots:
        for e in pot.entries:
            entries_by_pid[e['player_id']].append(
                {'game': pot.label, 'amount': e['amount']})
        for p in pot.prizes:
            prizes_by_pid[p['player_id']].append(
                {'game': pot.label, 'amount': p['amount'],
                 'detail': p['detail']})

    golfers = []
    for pid, name in field.items():
        entries = entries_by_pid.get(pid, [])
        prizes  = prizes_by_pid.get(pid, [])
        paid_in = sum(e['amount'] for e in entries)
        won     = sum(p['amount'] for p in prizes)
        golfers.append({
            'player_id': pid,
            'name'     : name,
            'entries'  : entries,
            'prizes'   : prizes,
            'staked'   : round(paid_in, 2),
            'won'      : round(won, 2),
            'net'      : round(won - paid_in, 2),
        })

    # Collects first, sorted by amount — the man owed the most wants to see it
    # first. Pays follow, and his total is always exactly what he staked.
    golfers.sort(key=lambda g: (-g['net'], g['name']))

    # ── The checks ────────────────────────────────────────────────────────
    blocking = []
    for pot in pots:
        if not pot.balanced:
            direction = 'over' if pot.difference < 0 else 'under'
            blocking.append(
                f"{pot.label} does not balance — ${abs(pot.difference):,.2f} "
                f"{direction}paid. The mistake is in its payout table."
            )

    rounds = list(tournament.rounds.all())
    # RoundStatus.COMPLETE is 'complete'.  Comparing to the literal
    # 'completed' matched nothing, so this blocked forever and Settle
    # could never be pressed on a finished tournament.
    if not rounds or not all(r.status == RoundStatus.COMPLETE
                             for r in rounds):
        blocking.append(
            'Every round has to be closed before the tournament settles — the '
            'day bet cannot resolve until the championship does.'
        )

    total_collected = round(sum(g['net'] for g in golfers if g['net'] > 0), 2)
    total_paid      = round(-sum(g['net'] for g in golfers if g['net'] < 0), 2)
    sum_zero        = abs(total_collected - total_paid) <= CENT_SLACK
    if not sum_zero:
        blocking.append(
            f'Collected (${total_collected:,.2f}) and paid '
            f'(${total_paid:,.2f}) do not cancel. The golfers fund this '
            f'entirely, so any other answer is an arithmetic bug.'
        )

    return {
        'golfers'        : golfers,
        'games'          : [p.as_dict() for p in pots],
        'balanced'       : all(p.balanced for p in pots),
        'blocking'       : blocking,
        'can_settle'     : not blocking,
        'total_collected': total_collected,
        'total_paid'     : total_paid,
        'sum_zero'       : sum_zero,
        'excluded_note'  : (
            'Foursome side bets settle in the group. Skins, Nassau and spots '
            'are not included in these totals — the foursome sorts those out '
            'itself.'
        ),
    }
