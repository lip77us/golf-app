"""
services/settlement.py
----------------------
Cross-game settlement for a round: sum every configured game's signed,
zero-sum per-player net into one "who owes whom" summary.  This is what the
leaderboard's **Settlement** tab renders, and the building block the
year-to-date / tournament betting views will reuse.

Each game already returns a signed per-player net in its own summary (the
payout-mode work standardized this on services.wager.settle):

    skins/spots      → summary['players'][*]['net']
    points_531/wolf  → summary['players'][*]['money']
    sixes/fourball   → summary['money']['by_player'][*]['amount']
    low_net_round    → results[*]['payout'] − entry_fee (non-excluded)
    stableford       → per_point: results[*]['payout'];
                       pool:      results[*]['payout'] − entry_fee

Team games that don't expose a clean per-player net yet (Nassau, Vegas,
Multi-Skins, Triple Cup, …) are reported under ``uncovered_games`` so the UI
can note "not included" rather than silently dropping money.
"""
from collections import defaultdict

# Games whose per-player net we can extract today.  Anything active but not
# here is surfaced as uncovered.
NETTABLE = {
    'skins', 'spots', 'points_531', 'wolf', 'sixes', 'fourball',
    'low_net_round', 'stableford', 'match_play',
}

_LABELS = {
    'skins': 'Skins', 'spots': 'Spots', 'points_531': 'Points 5-3-1',
    'wolf': 'Wolf', 'sixes': "Six's", 'fourball': 'Fourball',
    'low_net_round': 'Stroke Play', 'stableford': 'Stableford',
    'match_play': 'Singles Bracket',
}


def _pid_nets_for_game(game_key, round_obj, foursomes):
    """Return ``{player_id: net}`` for one game across the whole round."""
    out = defaultdict(float)

    if game_key == 'skins':
        from services.skins import skins_summary
        for fs in foursomes:
            for p in skins_summary(fs).get('players', []):
                out[p['player_id']] += p.get('net', p.get('payout', 0)) or 0

    elif game_key == 'spots':
        from services.spots import spots_summary
        for fs in foursomes:
            for p in spots_summary(fs).get('players', []):
                out[p['player_id']] += p.get('net', p.get('payout', 0)) or 0

    elif game_key == 'points_531':
        from services.points_531 import points_531_summary
        for fs in foursomes:
            for p in points_531_summary(fs).get('players', []):
                out[p['player_id']] += p.get('money', 0) or 0

    elif game_key == 'wolf':
        from services.wolf import wolf_summary
        for fs in foursomes:
            for p in wolf_summary(fs).get('players', []):
                out[p['player_id']] += p.get('money', 0) or 0

    elif game_key == 'sixes':
        from services.sixes import sixes_summary
        for fs in foursomes:
            for p in (sixes_summary(fs).get('money', {}) or {}).get('by_player', []):
                out[p['player_id']] += p.get('amount', 0) or 0

    elif game_key == 'fourball':
        from services.fourball import fourball_summary
        for fs in foursomes:
            s = fourball_summary(fs) or {}
            for p in (s.get('money', {}) or {}).get('by_player', []):
                out[p['player_id']] += p.get('amount', 0) or 0

    elif game_key == 'low_net_round':
        from services.low_net_round import low_net_round_summary
        s = low_net_round_summary(round_obj)
        entry = s.get('entry_fee', 0) or 0
        for r in s.get('results', []):
            if r.get('excluded'):
                continue
            out[r['player_id']] += (r.get('payout') or 0) - entry

    elif game_key == 'stableford':
        from services.stableford import stableford_summary
        s = stableford_summary(round_obj)
        entry = s.get('entry_fee', 0) or 0
        per_point = s.get('payout_style') == 'per_point'
        for r in s.get('results', []):
            if r.get('excluded'):
                continue
            payout = r.get('payout') or 0
            out[r['player_id']] += payout if per_point else payout - entry

    elif game_key == 'match_play':
        # Single-elim mini bracket → places-paid pool.  Only settles once the
        # bracket is COMPLETE (places decided); mid-round it's undecided, so we
        # net nothing (keeps the tab zero-sum instead of showing everyone the
        # ante with no winner).
        from services.tournament_match_play import tournament_match_play_summary
        for fs in foursomes:
            s = tournament_match_play_summary(fs)
            if not s or s.get('status') != 'complete':
                continue
            money = s.get('money', {}) or {}
            entry = money.get('entry_fee', 0) or 0
            for p in s.get('players', []):            # every bracket player antes
                out[p['player_id']] -= entry
            for po in (money.get('payouts', []) or []):
                pid = po.get('player_id')
                if pid is not None:
                    out[pid] += po.get('amount', 0) or 0

    return out


def _who_owes_whom(nets, names):
    """Greedy minimum-transaction settlement from signed per-player nets.

    ``nets`` : {player_id: net}.  Returns a list of transfers
    ``{'from','to','from_name','to_name','amount'}`` (from pays to).
    """
    creditors = sorted(([pid, round(n, 2)] for pid, n in nets.items()
                        if round(n, 2) > 0), key=lambda x: -x[1])
    debtors   = sorted(([pid, round(-n, 2)] for pid, n in nets.items()
                        if round(n, 2) < 0), key=lambda x: -x[1])
    transfers = []
    i = j = 0
    while i < len(debtors) and j < len(creditors):
        d, c = debtors[i], creditors[j]
        amt = round(min(d[1], c[1]), 2)
        if amt > 0:
            transfers.append({
                'from': d[0], 'to': c[0],
                'from_name': names.get(d[0], {}).get('short_name', ''),
                'to_name':   names.get(c[0], {}).get('short_name', ''),
                'amount': amt,
            })
        d[1] = round(d[1] - amt, 2)
        c[1] = round(c[1] - amt, 2)
        if d[1] <= 0.005:
            i += 1
        if c[1] <= 0.005:
            j += 1
    return transfers


def round_settlement(round_obj) -> dict | None:
    """Net every configured game into one per-player settlement.

    Returns ``None`` when the round has no nettable game (nothing to settle),
    else::

        {
          'players': [{'player_id','name','short_name','net'}, ...],  # net desc
          'per_game': [{'game','label','nets':{player_id: net}}, ...],
          'transfers': [{'from','to','from_name','to_name','amount'}, ...],
          'uncovered_games': ['nassau', ...],   # active but not yet nettable
        }
    """
    foursomes = list(round_obj.foursomes.all())

    # Effective active set = round games + any foursome-level games (e.g. a
    # per-foursome Singles Bracket), round games first for stable ordering.
    active = list(round_obj.active_games or [])
    for fs in foursomes:
        for g in (fs.active_games or []):
            if g not in active:
                active.append(g)

    covered = [g for g in active if g in NETTABLE]
    if not covered:
        return None

    # Names (+ short names) from the real roster.
    names = {}
    for fs in foursomes:
        for m in fs.memberships.select_related('player').all():
            if m.player.is_phantom:
                continue
            names.setdefault(m.player_id, {
                'name': m.player.name, 'short_name': m.player.short_name})

    nets = defaultdict(float)
    per_game = []
    for g in covered:
        pid_net = _pid_nets_for_game(g, round_obj, foursomes)
        if not pid_net:
            continue
        rounded = {pid: round(v, 2) for pid, v in pid_net.items()}
        per_game.append({'game': g, 'label': _LABELS.get(g, g), 'nets': rounded})
        for pid, v in pid_net.items():
            nets[pid] += v

    # Nothing actually settled (e.g. only an as-yet-undecided bracket) → no tab.
    if not per_game:
        return None

    players = sorted(
        ({'player_id': pid,
          'name': names.get(pid, {}).get('name', ''),
          'short_name': names.get(pid, {}).get('short_name', ''),
          'net': round(v, 2)}
         for pid, v in nets.items()),
        key=lambda e: (-e['net'], e['name']),
    )

    uncovered = [g for g in active
                 if g not in NETTABLE and g not in ('match_18',)]

    return {
        'players': players,
        'per_game': per_game,
        'transfers': _who_owes_whom(nets, names),
        'uncovered_games': uncovered,
    }
