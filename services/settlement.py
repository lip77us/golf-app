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

    forty_balls/     group pools (§4 Group B): the group's per-person share
    hot_spot         minus the entry, refused when the table does not pay
                     out the pool

Team games that don't expose a clean per-player net yet (Vegas, Multi-Skins,
Triple Cup, …) are reported under ``uncovered_games`` so the UI can note "not
included" rather than silently dropping money.  **Nassau, Rabbit and Survivor
used to be on that list and are not any more** — the settle-up receipt (§4
Group A) wired the ledgers their engines already produced.
"""
import logging
from collections import defaultdict

from tournament.models import FoursomeMembership

logger = logging.getLogger(__name__)

# Games whose per-player net we can extract today.  Anything active but not
# here is surfaced as uncovered.
NETTABLE = {
    'skins', 'spots', 'points_531', 'wolf', 'sixes', 'fourball',
    'low_net_round', 'stableford', 'match_play', 'triple_nassau',
    'annandale_friday',
    # Added with the settle-up receipt (handoff §4 Group A), which lists all
    # three as "the engine already produces a zero-sum ledger".  It did; it
    # had simply never been wired in here, so 11 of 40 completed casual rounds
    # in the local database — 5 Nassau, 3 Survivor, 3 Rabbit — could produce
    # no settlement and no receipt at all.
    'nassau', 'rabbit', 'survivor',
    # Group B (§4) — the GROUP pools.  Each group's payout is divided across
    # its golfers, and a golfer's net is his share minus his entry.
    'forty_balls', 'hot_spot',
    # Both engines already produced a zero-sum per-golfer ledger and neither
    # was wired in, so a Banker or Sequoya round settled to nothing and could
    # never reach a receipt — their §4 detail formatters were unreachable by
    # construction.  Verified zero-sum against every such round in the local
    # database before being added.
    'banker', 'sequoya_threes',
}

_LABELS = {
    'skins': 'Skins', 'spots': 'Spots', 'points_531': 'Points 5-3-1',
    'wolf': 'Wolf', 'sixes': 'Sixes', 'fourball': 'Fourball',
    'low_net_round': 'Stroke Play', 'stableford': 'Stableford',
    'match_play': 'Singles Bracket', 'triple_nassau': 'Triple Nassau',
    'annandale_friday': 'Annandale Friday',
    'sequoya_threes': 'Sequoya 3s',
    'nassau': 'Nassau', 'rabbit': 'Rabbit', 'survivor': 'Survivor',
    'forty_balls': '40 Balls', 'hot_spot': 'Hot Seat',
    'banker': 'Banker',
}


def _is_cup_round(round_obj) -> bool:
    """A team-cup round plays for POINTS, so its matches settle no money."""
    try:
        _ = round_obj.ryder_cup_config
        return True
    except Exception:
        return False


def _group_pool_nets(game_key, round_obj) -> dict:
    """§4 Group B: a GROUP pool, netted per golfer.

    "Each group's payout is divided across its golfers", and §2.3's net is
    ``payout − entry``.  Both halves come from the engine: the ranking, the
    tie splitting and the per-person share are ``services.group_field``'s, and
    re-deriving them here would be a second opinion about money — the failure
    this codebase has collected scars from.

    **It refuses an unbalanced pool rather than reporting one.**  With entries
    uncollected there is nobody holding the difference, so a table that does
    not pay out the pool has no set of transfers that clears it: a $120 pot
    paying $80 leaves $40 belonging to nobody.  Returning nothing makes the
    game read as uncovered, which is true, instead of handing the receipt a
    ledger that cannot settle.
    """
    from collections import defaultdict
    if game_key == 'forty_balls':
        from services.forty_balls import forty_balls_summary as summary_fn
    else:
        from services.hot_spot import hot_spot_summary as summary_fn
    s = summary_fn(round_obj) or {}
    entry = float(s.get('entry_fee') or 0)
    rows = s.get('results') or s.get('standings') or []
    if not rows:
        return {}

    nets, members = defaultdict(float), {}
    for m in FoursomeMembership.objects.filter(
            foursome__round=round_obj,
            player__is_phantom=False).select_related('player'):
        members.setdefault(m.foursome_id, []).append(m.player_id)

    for row in rows:
        ids = members.get(row.get('foursome_id')) or []
        share = float(row.get('per_person_payout') or 0)
        for pid in ids:
            nets[pid] += share - entry

    total = round(sum(nets.values()), 2)
    if total:
        logger.warning(
            '%s on round %s pays out %s short of its pool; not nettable',
            game_key, round_obj.id, total)
        return {}
    return dict(nets)


def _pid_nets_for_game(game_key, round_obj, foursomes):
    """Return ``{player_id: net}`` for one game across the whole round."""
    out = defaultdict(float)

    if game_key == 'skins':
        from services.skins import skins_summary
        for fs in foursomes:
            for p in skins_summary(fs).get('players', []):
                out[p['player_id']] += p.get('net', p.get('payout', 0)) or 0

    elif game_key == 'nassau':
        from services.nassau import nassau_summary
        for fs in foursomes:
            # §4: "Cup Nassau plays for points, not money, so it gets no
            # receipt."  A cup match is scored for the team board; netting it
            # here would invent dollars nobody played for.
            if _is_cup_round(fs.round):
                continue
            s = nassau_summary(fs)
            if not s:
                continue
            # CAPPED, never `total`.  The loss cap is per side, and `total` is
            # the uncapped sum — settling on it pays out past the cap.  This
            # exact slip was a real money bug in Annandale Friday, whose
            # comment says so at the one other place this figure is read.
            total = float(s.get('payouts', {}).get('total_capped') or 0)
            if not total:
                continue
            # `total` is from team1's perspective and each golfer is paid it
            # (§4: "stake x result for each bet, paid to each player"), so the
            # sides must be the same size for the ledger to balance.  Nassau
            # is 1v1 or 2v2, so they are; an uneven split would be a different
            # game and is skipped rather than silently unbalanced.
            t1 = [pl['player_id'] for pl in s.get('teams', {}).get('team1', [])]
            t2 = [pl['player_id'] for pl in s.get('teams', {}).get('team2', [])]
            if not t1 or len(t1) != len(t2):
                continue
            for pid in t1:
                out[pid] += total
            for pid in t2:
                out[pid] -= total

    elif game_key in ('forty_balls', 'hot_spot'):
        out.update(_group_pool_nets(game_key, round_obj))

    elif game_key == 'rabbit':
        from services.rabbit import rabbit_summary
        for fs in foursomes:
            for p in (rabbit_summary(fs) or {}).get('players', []):
                out[p['player_id']] += p.get('money', 0) or 0

    elif game_key == 'survivor':
        from services.survivor import survivor_summary
        for fs in foursomes:
            for p in (survivor_summary(fs) or {}).get('players', []):
                out[p['player_id']] += p.get('money', 0) or 0

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

    elif game_key == 'banker':
        from services.banker import banker_summary
        for fs in foursomes:
            for p in (banker_summary(fs) or {}).get('players', []):
                # `total` is banking + betting, already capped: `players[]`
                # carries `loss_cap` and the engine clips before reporting.
                # Decimal, so it is floated here rather than mixed.
                out[p['player_id']] += float(p.get('total') or 0)

    elif game_key == 'sequoya_threes':
        from services.sequoya_threes import sequoya_threes_summary
        for fs in foursomes:
            for p in (sequoya_threes_summary(fs) or {}).get('players', []):
                # SETTLED money, not `live_money` — the latter is what the
                # board shows mid-round and includes bets still running.
                out[p['player_id']] += float(p.get('money') or 0)

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

    elif game_key == 'sequoya_threes':
        # Six three-hole matches plus their presses, already netted per golfer
        # and zero-sum across the four.
        from services.sequoya_threes import sequoya_threes_summary
        for fs in foursomes:
            s = sequoya_threes_summary(fs)
            if not s:
                continue
            for p in s.get('players', []):
                out[p['player_id']] += p.get('money', 0) or 0

    elif game_key == 'triple_nassau':
        # Round-robin of three 1v1 Nassaus — each match is zero-sum between its
        # pair, and the summary already sums each player's two matches into
        # `net`, so the tab just adds those up (zero-sum across the group).
        from services.triple_nassau import triple_nassau_summary
        for fs in foursomes:
            s = triple_nassau_summary(fs)
            if not s:
                continue
            for p in s.get('players', []):
                out[p['player_id']] += p.get('net', 0) or 0

    elif game_key == 'annandale_friday':
        # Three better-ball Nassaus; the summary has already netted each
        # golfer's two or three matches into `net`, zero-sum across the card.
        from services.annandale_friday import annandale_friday_summary
        for fs in foursomes:
            s = annandale_friday_summary(fs)
            if not s:
                continue
            for p in s.get('players', []):
                out[p['player_id']] += p.get('net', 0) or 0

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


def player_round_net(round_obj, player_id, foursomes=None) -> float | None:
    """A single player's net across ALL nettable games in the round.

    Unlike :func:`round_settlement` (a cross-game tab that only appears for 2+
    settled games), this sums every nettable game — so a one-game round still
    reports its money.  Used by the rounds list to show each round's result.

    Returns ``None`` when no nettable game is configured (caller omits money),
    else the player's total net (may legitimately be ``0.0`` — an even round).
    """
    foursomes = foursomes if foursomes is not None \
        else list(round_obj.foursomes.all())

    active = list(round_obj.active_games or [])
    for fs in foursomes:
        for g in (fs.active_games or []):
            if g not in active:
                active.append(g)

    covered = [g for g in active if g in NETTABLE]
    if not covered:
        return None

    total = 0.0
    for g in covered:
        pid_net = _pid_nets_for_game(g, round_obj, foursomes)
        total += pid_net.get(player_id, 0.0) or 0.0
    return round(total, 2)


def round_settlement(round_obj, *, min_games: int = 2) -> dict | None:
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

    # The Settlement TAB is a cross-game view — only worth showing when 2+
    # games actually settled, since a single game's payouts already live on its
    # own tab and a one-game Settlement tab would just restate them. (Also
    # covers "nothing settled yet", e.g. only an as-yet-undecided bracket.)
    #
    # That is a rule about DISPLAY, not about whether money exists, so it is a
    # parameter rather than a fact. The receipt passes min_games=1: a skins-only
    # round is the commonest casual round there is, and "Ben owes you $12" is
    # exactly as true with one game as with two.
    if len(per_game) < min_games:
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
