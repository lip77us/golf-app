"""
services/spots.py
-----------------
Spots — a capture add-on settled on its OWN pot (never folded into the main
game).  A "spot" is a user-defined per-hole achievement (one-putt, sandy,
barky, …) the app can't detect; the scorer tallies them by hand per player per
hole (like junk), and the count IS the data — nothing is derived from gross
scores, so there's no recalc step.

Settlement:
  - pay_around (default): each spot pays the achiever 1 × bet_unit from every
    OTHER active player on that hole — zero-sum within the hole's roster.
  - pool: each active player antes bet_unit; the pot is split proportional to
    spots won (skins-style).  bet_unit acts as the ante here.

Mid-round withdrawal: a player only pays/collects on holes they're active for
(not withdrawn before that hole), mirroring Skins.
"""

from django.db import transaction

from core.models import MatchStatus, RoundStatus
from games.models import SpotsGame, SpotsPlayerHoleResult


def setup_spots(foursome, bet_unit=None, payout_style='pay_around') -> SpotsGame:
    """Create (or replace) the Spots game for a foursome. Replacing cascades to
    all SpotsPlayerHoleResult rows, so it starts fresh."""
    SpotsGame.objects.filter(foursome=foursome).delete()
    if bet_unit is None:
        bet_unit = foursome.round.bet_unit
    if payout_style not in ('pay_around', 'pool'):
        payout_style = 'pay_around'
    return SpotsGame.objects.create(
        foursome     = foursome,
        bet_unit     = bet_unit,
        payout_style = payout_style,
        status       = MatchStatus.PENDING,
    )


@transaction.atomic
def tally_spots(foursome, hole_number: int, entries: list) -> SpotsGame:
    """Upsert per-player spot counts for one hole.

    entries: [{'player_id': int, 'count': int}, ...]. A count of 0 deletes the
    row. Unmentioned players are left untouched.
    """
    game = foursome.spots_game  # caller guarantees it exists
    real_ids = {
        m.player_id for m in foursome.memberships.filter(player__is_phantom=False)
    }
    for e in entries:
        pid = e.get('player_id')
        if pid not in real_ids:
            continue
        count = int(e.get('count') or 0)
        if count == 0:
            SpotsPlayerHoleResult.objects.filter(
                game=game, player_id=pid, hole_number=hole_number).delete()
        else:
            SpotsPlayerHoleResult.objects.update_or_create(
                game=game, player_id=pid, hole_number=hole_number,
                defaults={'count': count})

    if game.status == MatchStatus.PENDING:
        game.status = MatchStatus.IN_PROGRESS
        game.save(update_fields=['status'])
    return game


def _active_roster_by_hole(real_members) -> dict:
    """{hole: [player_id, ...]} of players active on each hole (not withdrawn
    before it). Mirrors Skins' active-on-hole rule."""
    all_pids = [m.player_id for m in real_members]
    wd = {m.player_id: m.withdrew_after_hole
          for m in real_members if m.withdrew_after_hole is not None}
    return {
        h: [pid for pid in all_pids if pid not in wd or h <= wd[pid]]
        for h in range(1, 19)
    }


def spots_summary(foursome) -> dict:
    """JSON-serialisable summary (shape mirrors skins_summary for the UI)."""
    bet_unit_default = float(foursome.round.bet_unit)
    try:
        game = foursome.spots_game
    except SpotsGame.DoesNotExist:
        return {
            'status'      : MatchStatus.PENDING,
            'payout_style': 'pay_around',
            'players'     : [],
            'holes'       : [],
            'money'       : {'bet_unit': bet_unit_default, 'total_spots': 0},
        }

    real_members = list(
        foursome.memberships.select_related('player')
        .filter(player__is_phantom=False)
    )
    bet_unit = float(game.bet_unit)
    roster   = _active_roster_by_hole(real_members)

    rows = list(SpotsPlayerHoleResult.objects
                .filter(game=game).exclude(count=0)
                .select_related('player'))

    # count[pid] and per-hole tallies
    totals  = {m.player_id: 0 for m in real_members}
    by_hole: dict = {}
    for r in rows:
        totals[r.player_id] = totals.get(r.player_id, 0) + r.count
        by_hole.setdefault(r.hole_number, []).append(r)

    # ---- settlement ---------------------------------------------------------
    net = {m.player_id: 0.0 for m in real_members}
    if game.payout_style == 'pool':
        # Everyone antes one bet_unit (the pot = each player's max loss). The
        # pot is then handed to the "winners":
        #   - if anyone is positive: split among positive players proportional
        #     to their positive spots (negatives/zeros get nothing);
        #   - else: the least-negative player(s) take it, split on a tie.
        ante = bet_unit
        pot  = ante * len(real_members)
        positives = {pid: c for pid, c in totals.items() if c > 0}
        shares = {}
        if positives:
            spos = sum(positives.values())
            shares = {pid: pot * (c / spos) for pid, c in positives.items()}
        elif totals:
            top = max(totals.values())
            winners = [pid for pid, c in totals.items() if c == top]
            shares = {pid: pot / len(winners) for pid in winners}
        for m in real_members:
            net[m.player_id] = round(shares.get(m.player_id, 0.0) - ante, 2)
    else:  # pay_around
        for h, hrows in by_hole.items():
            active = roster.get(h, [])
            if len(active) < 2:
                continue
            spots_on_hole = {pid: 0 for pid in active}
            for r in hrows:
                if r.player_id in spots_on_hole:
                    spots_on_hole[r.player_id] += r.count
            total_h = sum(spots_on_hole.values())
            n = len(active)
            for pid in active:
                net[pid] += bet_unit * (spots_on_hole[pid] * n - total_h)
        net = {pid: round(v, 2) for pid, v in net.items()}

    short = {m.player_id: (m.player.display_short
                           if hasattr(m.player, 'display_short') else m.player.name)
             for m in real_members}
    players = sorted(
        ({'player_id': m.player_id,
          'name'      : m.player.name,
          'short_name': short[m.player_id],
          'spots'     : totals[m.player_id],
          'payout'    : net[m.player_id]}
         for m in real_members),
        key=lambda p: p['spots'], reverse=True)

    holes = [
        {'hole': h,
         'spots': [{'player_id': r.player_id,
                    'short_name': short.get(r.player_id, r.player.name),
                    'count': r.count}
                   for r in sorted(by_hole[h], key=lambda r: r.player_id)]}
        for h in sorted(by_hole)
    ]

    round_done = foursome.round.status == RoundStatus.COMPLETE
    status = (MatchStatus.COMPLETE if round_done
              else (MatchStatus.IN_PROGRESS if rows else game.status))

    return {
        'status'      : status,
        'payout_style': game.payout_style,
        'players'     : players,
        'holes'       : holes,
        'money'       : {'bet_unit': bet_unit,
                         'total_spots': sum(totals.values())},
    }
