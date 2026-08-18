"""
services/day_bet.py
-------------------
The day bet — the final round's 18-hole stroke play side bet.
See docs/design-review/handoff-individual-play/SPEC.md §7.

The only board in the set whose result is not knowable while it is being
played. Two ways out of it, and only one of them is italic:

* **Not here at all** — the Mini Singles day-2 finalists. Playing a match, not
  posting a stroke card, so neither charged nor ranked. An absence, not an
  exclusion — they get no row.
* **Here but italic** — the championship money winners. They play the round
  and appear on the board but cannot collect, and do not contribute: their
  entry is returned at settlement. Only known when the championship closes,
  which is why they stay VISIBLE until then. Hiding them would make the board
  jump at the end with no explanation.

Everything about this board is provisional for the same reason, including the
pool: it reads from the assumption that the current 36-hole leaders hold. If
somebody else wins that money instead, one entry comes back in and another
goes out, and the places resize. Nothing is collected until the championship
closes, so no refund is ever actually handed back.

Ties share a position, carry T, and split the money for the places they
occupy — the same rule as every other board. **Ineligible rows hold a position
but do not consume a paid place**, so prize is shown against the first three
ELIGIBLE golfers, not the first three rows.

Public API
~~~~~~~~~~
    n      = places_for_field(eligible_count)
    rows   = day_bet_standings(round_obj)
    summary= day_bet_summary(round_obj)
"""
from services.low_net_round import _build_ln_player_totals
from services.payout import payouts_by_place, split_tied_places


# ---------------------------------------------------------------------------
# Places scale with the round, not the entry list
# ---------------------------------------------------------------------------

def places_for_field(eligible_count: int) -> int:
    """
    How many places a day bet of this size pays.

    Ten eligible pays three. Three places on a smaller field would pay most of
    the men who entered, which is not what this bet is for.
    """
    if eligible_count >= 10:
        return 3
    if eligible_count >= 6:
        return 2
    if eligible_count >= 2:
        return 1
    return 0


# ---------------------------------------------------------------------------
# Who is out, and why
# ---------------------------------------------------------------------------

def _championship_money_ids(tournament) -> dict:
    """
    ``{player_id: place_label}`` for everyone currently in the 36-hole money.

    Reads the tournament's OWN handicap setting rather than naming a scoring
    type: a net event disqualifies the net money winners, a gross event the
    gross ones. The championship calculator already scores in the configured
    mode, so following its paying places is the whole rule.
    """
    method = (tournament.scoring_method or 'stroke')
    if method == 'stableford':
        from services.stableford_championship import (
            stableford_championship_standings as standings_fn)
    else:
        from services.low_net_championship import (
            low_net_championship_standings as standings_fn)

    out = {}
    for row in standings_fn(tournament):
        if row.get('payout'):
            place = row['rank']
            suffix = {1: 'st', 2: 'nd', 3: 'rd'}.get(place, 'th')
            out[row['player_id']] = f'{place}{suffix}'
    return out


def _tournament_closed(tournament) -> bool:
    """True once every round has finished — the day bet resolves last."""
    rounds = list(tournament.rounds.all())
    return bool(rounds) and all(r.status == 'completed' for r in rounds)


# ---------------------------------------------------------------------------
# Standings
# ---------------------------------------------------------------------------

def day_bet_standings(round_obj) -> list:
    """
    Every golfer on the day-bet board, ranked, with eligibility resolved.

    Row shape::

        {'rank', 'player_id', 'player_name', 'net_total', 'net_to_par',
         'holes_played', 'eligible', 'ineligible_reason', 'payout'}

    Day-2 finalists are absent entirely; championship money winners are
    present, flagged ineligible, and hold a position without consuming a
    paid place.
    """
    tournament = round_obj.tournament
    if tournament is None:
        return []

    from services.mini_singles import day2_finalist_ids
    absent   = day2_finalist_ids(tournament)
    in_money = _championship_money_ids(tournament)

    totals = _build_ln_player_totals(
        round_obj, tournament.handicap_mode, tournament.net_percent,
        force_cap=tournament.is_individual_play)

    rows = [
        (pid, data) for pid, data in totals.items()
        if pid not in absent and data['holes_played'] > 0
    ]
    rows.sort(key=lambda kv: (kv[1]['total'] - kv[1]['par_played'],
                              -kv[1]['holes_played']))

    # Display ranks over EVERY row, ineligible included — an ineligible golfer
    # really is ahead of the men below him on the card.
    ranked = []
    rank = 1
    for i, (pid, data) in enumerate(rows):
        ntp = data['total'] - data['par_played']
        if i > 0 and ntp > (rows[i - 1][1]['total'] - rows[i - 1][1]['par_played']):
            rank = i + 1
        ranked.append((pid, data, rank))

    # Prize ranks over the ELIGIBLE only: an italic row above them is the
    # normal case and must not swallow a place.
    config   = getattr(round_obj, 'day_bet_config', None)
    places   = payouts_by_place(config.payouts) if config else {}
    eligible = [(pid, data) for pid, data, _r in ranked if pid not in in_money]

    prize_rank = {}
    r = 1
    for i, (pid, data) in enumerate(eligible):
        ntp = data['total'] - data['par_played']
        if i > 0 and ntp > (eligible[i - 1][1]['total'] - eligible[i - 1][1]['par_played']):
            r = i + 1
        prize_rank[pid] = r
    per_rank = split_tied_places(places, list(prize_rank.values()))

    out = []
    for pid, data, display_rank in ranked:
        ineligible_place = in_money.get(pid)
        out.append({
            'rank'             : display_rank,
            'player_id'        : pid,
            'player_name'      : data['name'],
            'net_total'        : data['total'],
            'net_to_par'       : data['total'] - data['par_played'],
            'holes_played'     : data['holes_played'],
            'eligible'         : ineligible_place is None,
            # The subtitle on an italic row says WHERE he is in the money —
            # "1st", "2nd", "3rd" — so the reader can see why he drops out.
            'ineligible_reason': (None if ineligible_place is None
                                  else f'In the 36-hole money — {ineligible_place}'),
            'payout'           : (per_rank.get(prize_rank.get(pid)) or None
                                  if ineligible_place is None else None),
        })
    return out


def day_bet_summary(round_obj) -> dict | None:
    """
    Serialisable day-bet board, or None when this round has no day bet.

    Everything on it is provisional until the championship closes, which is
    what ``provisional`` flags and what keeps the Settle button off.
    """
    config = getattr(round_obj, 'day_bet_config', None)
    if config is None:
        return None

    tournament = round_obj.tournament
    rows       = day_bet_standings(round_obj)
    eligible   = [r for r in rows if r['eligible']]
    entry_fee  = float(config.entry_fee)

    from services.mini_singles import day2_finalist_ids
    absent = day2_finalist_ids(tournament) if tournament else set()

    handicap_word = 'net' if (tournament and tournament.handicap_mode == 'net') else 'gross'

    return {
        'configured' : True,
        'round_id'   : round_obj.id,
        'round_number': round_obj.round_number,
        'label'      : f'Day bet · R{round_obj.round_number}',
        'entry_fee'  : entry_fee,
        # The ineligible do not pay in, so the pool reads from the eligible
        # count and moves if the championship's money changes hands.
        'pool'       : round(entry_fee * len(eligible), 2),
        'eligible_count' : len(eligible),
        'places_supported': places_for_field(len(eligible)),
        'payouts'    : config.payouts or [],
        'absent_count': len(absent),
        'provisional': not _tournament_closed(tournament) if tournament else True,
        # Reads the tournament's setting rather than naming a scoring type.
        'dq_note'    : (f'Winners of 36-hole {handicap_word} money are not '
                        f'eligible.'),
        'absent_note': ('Mini Singles finalists are playing a match rather '
                        'than posting a card, so they are neither charged nor '
                        'ranked.') if absent else '',
        'results'    : rows,
    }
