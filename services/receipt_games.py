"""Per-game receipt language — settle-up handoff §4, Group A.

Group A is the easy third of §4 by design: "the engine already produces a
zero-sum ledger, so you only write ``summary``, ``detail`` and any caption
override."  Importing this module registers every formatter; nothing else has
to know they exist.

**The money is NOT here.**  Each game's ledger is wired into
``services.settlement._pid_nets_for_game``, and a formatter only decides what
the row SAYS.  That split is the point: a wrong summary is a wrong sentence,
and a wrong ledger is a wrong payment, so they are kept where they cannot be
confused for one another.

**Every figure is read from the engine's own summary.**  Nothing here re-derives
a result, a count or a margin.  This codebase's standing lesson is three
``gross_to_par`` implementations, one of which guessed the wrong key and
returned 0 invisibly — a summary row that quietly disagrees with the board
above it is the same failure with the golfer's money in it.
"""
from __future__ import annotations

from services.receipt_build import (
    GAME_CAPTION,
    GAME_DETAIL,
    GAME_STAKE,
    GAME_SUMMARY,
)
from services.settlement_receipt import money


def _foursomes(round_obj):
    return list(round_obj.foursomes.all())


def _short(names: dict, pid) -> str:
    e = names.get(pid) or {}
    return e.get('short_name') or e.get('name') or ''


def _by_money(entry: dict, names: dict, *, fmt=None) -> str:
    """"Kim +$9 · Reid −$2", biggest first — the generic money line."""
    fmt = fmt or (lambda v: money(v, sign=True))
    movers = sorted(entry['nets'].items(), key=lambda kv: -kv[1])
    return ' · '.join(f'{_short(names, pid)} {fmt(v)}' for pid, v in movers)


# ---------------------------------------------------------------------------
# Nassau
# ---------------------------------------------------------------------------

def _nine(block: dict, sign: int) -> str:
    """One nine's result FROM THE HEADLINE SIDE: "2 UP", "1 DN" or "AS".

    ``margin`` is signed from team1, so a nine the headline side LOST must be
    negated and read "DN".  Taking ``abs()`` and always writing UP produced
    "4 UP · front 1 UP, back 5 UP" on a real round — a row that does not add
    up, and the first thing a golfer checks.  §4 writes it "front 2 UP, back
    1 DN" for exactly this reason.
    """
    if not block:
        return ''
    result = (block.get('result') or '').lower()
    if not result:
        return ''
    if result == 'halved':
        return 'AS'
    margin = sign * int(block.get('margin') or 0)
    if margin == 0:
        return 'AS'
    return f'{abs(margin)} {"UP" if margin > 0 else "DN"}'


def nassau_summary_rows(round_obj, entry, names):
    """§4: ``["Nassau", "Lipkin/Kim 1 UP · front 2 UP, back 1 DN"]``.

    **Written from the winning side's view**, which is what makes "1 UP"
    readable on a document four golfers share: the row names who is up before
    it says by how much, so the number never has to be mentally reversed —
    and every nine after it is signed from that same side.

    Who the headline side is comes from the OVERALL match, not from the money:
    the money is the sum of three bets and the presses, so on a round where
    the overall was halved it names a side that did not win anything in
    particular.  The money is only the tie-break.
    """
    from services.nassau import nassau_summary
    rows = []
    for fs in _foursomes(round_obj):
        s = nassau_summary(fs)
        if not s:
            continue
        t1 = s.get('teams', {}).get('team1', [])
        t2 = s.get('teams', {}).get('team2', [])
        if not t1 or not t2:
            continue
        overall = s.get('overall') or {}
        result = (overall.get('result') or '').lower()
        if result == 'team1':
            team1_up = True
        elif result == 'team2':
            team1_up = False
        else:
            team1_up = float(s.get('payouts', {}).get('total_capped') or 0) >= 0
        sign = 1 if team1_up else -1
        side = '/'.join(pl.get('short_name') or pl.get('name', '')
                        for pl in (t1 if team1_up else t2))

        head_text = _nine(overall, sign)
        nines = []
        for key, label in (('front9', 'front'), ('back9', 'back')):
            text = _nine(s.get(key), sign)
            if text:
                nines.append(f'{label} {text}')
        head = f'{side} {head_text}' if head_text else side
        value = head + (' · ' + ', '.join(nines) if nines else '')
        rows.append(['Nassau', value])
    return rows


def nassau_stake(round_obj) -> str:
    from services.nassau import nassau_summary
    for fs in _foursomes(round_obj):
        s = nassau_summary(fs)
        if s and s.get('bet_unit'):
            return f'{money(s["bet_unit"])} a match'
    return ''


GAME_SUMMARY['nassau'] = nassau_summary_rows
GAME_STAKE['nassau'] = nassau_stake


# ---------------------------------------------------------------------------
# Rabbit
# ---------------------------------------------------------------------------

def rabbit_summary_rows(round_obj, entry, names):
    """§4: ``["Rabbit", "Kim 2 · Reid 1 · 1 loose"]``.

    **A loose rabbit is counted and named**, because it is the one outcome a
    golfer cannot read off the money: nobody won it and nobody paid for it, so
    without the count the rabbits do not add up to the round.
    """
    from services.rabbit import rabbit_summary
    rows = []
    for fs in _foursomes(round_obj):
        s = rabbit_summary(fs) or {}
        segs = [sg for sg in s.get('segments', []) if sg.get('complete')]
        if not segs:
            continue
        won, loose = {}, 0
        for sg in segs:
            holder = sg.get('holder_id')
            if holder:
                won[holder] = won.get(holder, 0) + 1
            else:
                loose += 1
        parts = [f'{_short(names, pid)} {n}' for pid, n in
                 sorted(won.items(), key=lambda kv: -kv[1])]
        if loose:
            parts.append(f'{loose} loose')
        rows.append(['Rabbit', ' · '.join(parts)])
    return rows


def rabbit_stake(round_obj) -> str:
    from services.rabbit import rabbit_summary
    for fs in _foursomes(round_obj):
        s = rabbit_summary(fs) or {}
        unit = (s.get('money') or {}).get('bet_unit')
        if unit:
            return f'{money(unit)} a rabbit'
    return ''


GAME_SUMMARY['rabbit'] = rabbit_summary_rows
GAME_STAKE['rabbit'] = rabbit_stake


# ---------------------------------------------------------------------------
# Survivor
# ---------------------------------------------------------------------------

def survivor_summary_rows(round_obj, entry, names):
    """§4: ``["Survivor", "Reid 2 · Kim 1 · 1 no blood"]``.

    **No blood is counted, for the same reason a loose rabbit is**: a Survivor
    that reached the last hole unresolved pays nobody, so the wins alone do not
    account for the round.  A **killed** Survivor is counted among the wins and
    not in the money — the Zombie genuinely won it and is credited the trophy,
    which is the engine's own deliberate call.
    """
    from services.survivor import survivor_summary
    rows = []
    for fs in _foursomes(round_obj):
        s = survivor_summary(fs) or {}
        legs = [lg for lg in s.get('survivors', []) if lg.get('complete')]
        if not legs:
            continue
        won, no_blood = {}, 0
        for lg in legs:
            winner = lg.get('winner_id')
            if lg.get('outcome') == 'no_blood' or not winner:
                no_blood += 1
            else:
                won[winner] = won.get(winner, 0) + 1
        parts = [f'{_short(names, pid)} {n}' for pid, n in
                 sorted(won.items(), key=lambda kv: -kv[1])]
        if no_blood:
            parts.append(f'{no_blood} no blood')
        rows.append(['Survivor', ' · '.join(parts)])
    return rows


def survivor_stake(round_obj) -> str:
    from services.survivor import survivor_summary
    for fs in _foursomes(round_obj):
        s = survivor_summary(fs) or {}
        unit = (s.get('money') or {}).get('bet_unit')
        if unit:
            return f'{money(unit)} a Survivor'
    return ''


GAME_SUMMARY['survivor'] = survivor_summary_rows
GAME_STAKE['survivor'] = survivor_stake


def _signed(value) -> str:
    """"+9", "−2", "E" — a signed COUNT, not money.

    A true minus (U+2212), the same character ``money()`` uses, so a points
    column and a money column line up under a proportional font.
    """
    n = int(round(float(value or 0)))
    if n == 0:
        return 'E'
    return f'+{n}' if n > 0 else f'−{abs(n)}'


# ---------------------------------------------------------------------------
# Skins
# ---------------------------------------------------------------------------

def skins_summary_rows(round_obj, entry, names):
    """§4: ``["Skins", "Kim 4 · Lipkin 2 · Reid 1 · Alvarez 1"]``.

    **``total_skins``, not ``skins_won``** — junk is a share of the same pot,
    so the pot divides by the total.  Printing skins alone would give a golfer
    with two junk a row that does not account for his money, which is the one
    thing a receipt has to do.
    """
    from services.skins import skins_summary
    rows = []
    for fs in _foursomes(round_obj):
        s = skins_summary(fs) or {}
        won = [(p['player_id'], p.get('total_skins') or 0)
               for p in s.get('players', []) if (p.get('total_skins') or 0)]
        if not won:
            continue
        won.sort(key=lambda kv: -kv[1])
        rows.append(['Skins', ' · '.join(f'{_short(names, pid)} {n}'
                                         for pid, n in won)])
    return rows


def skins_stake(round_obj) -> str:
    from services.skins import skins_summary
    for fs in _foursomes(round_obj):
        unit = ((skins_summary(fs) or {}).get('money') or {}).get('bet_unit')
        if unit:
            return f'{money(unit)} a skin'
    return ''


GAME_SUMMARY['skins'] = skins_summary_rows
GAME_STAKE['skins'] = skins_stake


# ---------------------------------------------------------------------------
# Points 5-3-1
# ---------------------------------------------------------------------------

def _points_vs_target(s: dict) -> dict:
    """``{player_id: (points, v_target)}``.

    The target is the game's own ``par_per_hole`` over the holes that golfer
    PLAYED, not over 18 — a withdrawal would otherwise read as a collapse
    against a target he was never chasing.
    """
    par = float((s.get('money') or {}).get('par_per_hole') or 3)
    out = {}
    for p in s.get('players', []):
        pts = float(p.get('points') or 0)
        out[p['player_id']] = (pts, pts - par * int(p.get('holes_played') or 0))
    return out


def points_summary_rows(round_obj, entry, names):
    """§4: ``["Points", "Kim +9 · Reid −2 · Lee −7"]`` — against the target."""
    from services.points_531 import points_531_summary
    rows = []
    for fs in _foursomes(round_obj):
        vs = _points_vs_target(points_531_summary(fs) or {})
        if not vs:
            continue
        order = sorted(vs.items(), key=lambda kv: -kv[1][1])
        rows.append(['Points', ' · '.join(
            f'{_short(names, pid)} {_signed(v)}' for pid, (_, v) in order)])
    return rows


def points_captions(round_obj, player_ids) -> dict:
    """§4: ``"{pts} pts · v. target {±N}"`` — the unit is points, not strokes,
    so the default gross/net caption would describe a different game."""
    from services.points_531 import points_531_summary
    out = {}
    for fs in _foursomes(round_obj):
        for pid, (pts, v) in _points_vs_target(points_531_summary(fs) or {}).items():
            out[pid] = f'{pts:g} pts · v. target {_signed(v)}'
    return out


def points_stake(round_obj) -> str:
    from services.points_531 import points_531_summary
    for fs in _foursomes(round_obj):
        unit = ((points_531_summary(fs) or {}).get('money') or {}).get('bet_unit')
        if unit:
            return f'{money(unit)} a point'
    return ''


GAME_SUMMARY['points_531'] = points_summary_rows
GAME_CAPTION['points_531'] = points_captions
GAME_STAKE['points_531'] = points_stake


# ---------------------------------------------------------------------------
# Sixes
# ---------------------------------------------------------------------------

def sixes_summary_rows(round_obj, entry, names):
    """§4: ``["Sixes", "Settled 3 of 3"]``.

    **A voided segment is out of both counts.**  A withdrawal voids the
    segments it touches and they score nothing, so counting them would promise
    matches that were never played for.
    """
    from services.sixes import sixes_summary
    rows = []
    for fs in _foursomes(round_obj):
        segs = [sg for sg in (sixes_summary(fs) or {}).get('segments', [])
                if not sg.get('is_void')]
        if not segs:
            continue
        settled = sum(1 for sg in segs
                      if (sg.get('status') or '').lower() not in
                      ('', 'pending', 'in_progress'))
        rows.append(['Sixes', f'Settled {settled} of {len(segs)}'])
    return rows


def sixes_stake(round_obj) -> str:
    from services.sixes import sixes_summary
    for fs in _foursomes(round_obj):
        unit = ((sixes_summary(fs) or {}).get('money') or {}).get('bet_unit')
        if unit:
            return f'{money(unit)} a match'
    return ''


def sixes_detail(round_obj, entry, names):
    """§4: one row per match — ``["1 · holes 1–6", "Kim/Reid 2 UP"]``.

    This is the question the summary row deliberately does not answer.
    "Settled 3 of 3" is the §4 summary and is right for the ticket, which is
    one column wide; who won which match, and against whom, is the long form
    and belongs on the web receipt.

    **The holes are the ones the match PLAYED**, taken from the summary
    segment rather than its stored range — a match won 3&2 stores 1–6 and
    played 1–4, and the next match starts on the 5th.  Printing the stored
    range would claim two holes for a match that was already over.

    **The result sentence comes from `match_result_text`**, the same writer
    the score-entry band uses, so the receipt and the screen cannot disagree
    about a close-out.

    Partners are joined with ``&`` — the handoff writes ``Kim/Reid``, but
    every other surface in this app says "Paul & Jim" and one of them reading
    differently is worse than matching the mock.
    """
    from services.sixes import match_result_text, sixes_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        segs = (sixes_summary(fs) or {}).get('segments') or []
        if not segs:
            continue
        rows = []
        for n, seg in enumerate(segs, start=1):
            played = [h['hole'] for h in (seg.get('holes') or [])]
            if played:
                span = (f'holes {played[0]}–{played[-1]}' if len(played) > 1
                        else f'hole {played[0]}')
            else:
                span = f"holes {seg['start_hole']}–{seg['end_hole']}"
            # The extra match is marked, the same way the handoff marks an
            # extra rabbit `Ex`: it is a real match for real money, but it
            # exists only because an earlier one ended early.
            label = f'{n} Ex · {span}' if seg.get('is_extra') else f'{n} · {span}'
            rows.append([label, match_result_text(seg) or 'Not played'])
        if not rows:
            continue
        name = (f'Sixes · group {fs.group_number} · the matches' if multi
                else 'Sixes · the matches')
        out.append({'label': name, 'rows': rows})
    return out


GAME_SUMMARY['sixes'] = sixes_summary_rows
GAME_STAKE['sixes'] = sixes_stake
GAME_DETAIL['sixes'] = sixes_detail


# ---------------------------------------------------------------------------
# Wolf
# ---------------------------------------------------------------------------

def wolf_summary_rows(round_obj, entry, names):
    """§4 asks for "points per golfer" and nothing more.

    **The handoff flags this one itself**: "No settlement mock yet; confirm the
    copy before building."  So this is the plainest row that is certainly
    true — the figure the game is scored in — rather than an invented
    sentence that would have to be unpicked when the mock lands.
    """
    from services.wolf import wolf_summary
    rows = []
    for fs in _foursomes(round_obj):
        pts = [(p['player_id'], p.get('points') or 0)
               for p in (wolf_summary(fs) or {}).get('players', [])]
        if not pts:
            continue
        pts.sort(key=lambda kv: -kv[1])
        rows.append(['Wolf', ' · '.join(
            f'{_short(names, pid)} {v:g}' for pid, v in pts)])
    return rows


def wolf_stake(round_obj) -> str:
    from services.wolf import wolf_summary
    for fs in _foursomes(round_obj):
        unit = ((wolf_summary(fs) or {}).get('money') or {}).get('bet_unit')
        if unit:
            return f'{money(unit)} a point'
    return ''


GAME_SUMMARY['wolf'] = wolf_summary_rows
GAME_STAKE['wolf'] = wolf_stake


# ---------------------------------------------------------------------------
# Sequoya 3s
# ---------------------------------------------------------------------------

def sequoya_summary_rows(round_obj, entry, names):
    """§4, two rows: ``["Matches", "6 of three holes · best ball net"]`` and
    ``["Bets", "13 · 5 auto presses, 2 called"]``.

    A press IS a bet here — each one is a new bet at the same stake — so the
    bet count is the matches plus every press, and naming the two kinds of
    press is what explains the difference between 6 and 13.
    """
    from services.sequoya_threes import sequoya_threes_summary
    rows = []
    for fs in _foursomes(round_obj):
        s = sequoya_threes_summary(fs) or {}
        matches = s.get('matches') or []
        if not matches:
            continue
        bets = sum(int(m.get('bet_count') or 0) for m in matches)
        called = sum(len(p.get('manual_presses') or [])
                     for p in s.get('players', []))
        auto = max(0, bets - len(matches) - called)
        rows.append(['Matches',
                     f'{len(matches)} of three holes · best ball net'])
        parts = []
        if auto:
            parts.append(f'{auto} auto press{"es" if auto != 1 else ""}')
        if called:
            parts.append(f'{called} called')
        rows.append(['Bets', f'{bets}' + (f' · {", ".join(parts)}'
                                          if parts else '')])
    return rows


def sequoya_stake(round_obj) -> str:
    from services.sequoya_threes import sequoya_threes_summary
    for fs in _foursomes(round_obj):
        amount = (sequoya_threes_summary(fs) or {}).get('bet_amount')
        if amount:
            return f'{money(amount)} a match'
    return ''


GAME_SUMMARY['sequoya_threes'] = sequoya_summary_rows
GAME_STAKE['sequoya_threes'] = sequoya_stake


# ---------------------------------------------------------------------------
# Banker
# ---------------------------------------------------------------------------

def banker_summary_rows(round_obj, entry, names):
    """§4: a section of one row per golfer, ``"−$90 · +$290"``.

    Banking and betting are the two halves of a Banker round and they move
    independently — a golfer can bank badly and bet well — so the row states
    both rather than the net, which the chip above already carries.
    """
    from services.banker import banker_summary
    rows = []
    for fs in _foursomes(round_obj):
        players = (banker_summary(fs) or {}).get('players') or []
        if not players:
            continue
        for p in sorted(players, key=lambda e: -float(e.get('total') or 0)):
            rows.append([
                _short(names, p['player_id']),
                f'{money(p.get("banking") or 0, sign=True)} · '
                f'{money(p.get("betting") or 0, sign=True)}',
            ])
    return rows


def banker_captions(round_obj, player_ids) -> dict:
    """§4: ``"banked {n} · bet {±$}"``."""
    from services.banker import banker_summary
    out = {}
    for fs in _foursomes(round_obj):
        s = banker_summary(fs) or {}
        banked = {}
        for h in s.get('holes') or []:
            bid = h.get('banker_id')
            if bid:
                banked[bid] = banked.get(bid, 0) + 1
        for p in s.get('players') or []:
            pid = p['player_id']
            out[pid] = (f'banked {banked.get(pid, 0)} · '
                        f'bet {money(p.get("betting") or 0, sign=True)}')
    return out


def banker_stake(round_obj) -> str:
    """§3's example is a BAND, not a unit: "$5–$50 band"."""
    from services.banker import banker_summary
    for fs in _foursomes(round_obj):
        s = banker_summary(fs) or {}
        lo, hi = s.get('min_bet'), s.get('max_bet')
        if lo is not None and hi is not None:
            return f'{money(lo)}–{money(hi)} band'
    return ''


GAME_SUMMARY['banker'] = banker_summary_rows
GAME_CAPTION['banker'] = banker_captions
GAME_STAKE['banker'] = banker_stake


# ===========================================================================
# Group B — the pools (§4)
# ===========================================================================
#
# **These read the engines' payouts; they do not re-run ``settle_pool``.**
# §4 says to "use settlePool and supply the place order and the payout table",
# which is how you build a pool that does not exist yet.  All four of these
# already rank, split their ties and pay — `low_net_round` through
# `_rank_standings`, the group pools through `services.group_field`, Dream
# Round through `rank_in_flights`.  Settling them a second time here would be
# a second opinion about money, and the two would eventually disagree about a
# tie or an odd cent.  ``settle_pool`` stays for a pool that has no engine.

from services.receipt_build import GAME_IMAGE_CAPTION  # noqa: E402

#: Suffix by LAST DIGIT. Keying the whole number gives '21th'.
_ORDINAL = {1: 'st', 2: 'nd', 3: 'rd'}


def _place(rank) -> str:
    """"1st", "2nd", "11th" — a place a golfer reads, not a rank integer."""
    if not rank:
        return ''
    rank = int(rank)
    # 11th, 12th and 13th are the exception the last-digit rule gets wrong.
    if 11 <= rank % 100 <= 13:
        return f'{rank}th'
    return f'{rank}{_ORDINAL.get(rank % 10, "th")}'


# ---------------------------------------------------------------------------
# Stroke Play — only when there is a pot
# ---------------------------------------------------------------------------

def stroke_play_rows(round_obj, entry, names):
    """§4: ``["Stroke Play", "Kim 1st $60 · Reid 2nd $20"]``.

    **Only the places that were PAID.**  §4 lists Stroke Play as a pool game
    "only when there is a pot", and on a board of sixteen the row cannot be a
    full ranking — the chips above already carry every golfer.  What the row
    adds is who collected.

    The place is the PRIZE rank, not the board rank: an excluded golfer holds
    a position without being paid, so the man behind him collects 2nd while
    standing 3rd, and printing the board rank beside the money would make the
    two disagree on the same line.
    """
    from services.low_net_round import low_net_round_summary
    s = low_net_round_summary(round_obj) or {}
    paid = [r for r in (s.get('results') or [])
            if (r.get('payout') or 0) and not r.get('excluded')]
    if not paid:
        return []
    paid.sort(key=lambda r: (r.get('prize_rank') or r.get('rank') or 99))
    return [['Stroke Play', ' · '.join(
        f'{_short(names, r["player_id"])} '
        f'{_place(r.get("prize_rank") or r.get("rank"))} '
        f'{money(r["payout"])}' for r in paid)]]


def stroke_play_captions(round_obj, player_ids) -> dict:
    """§4: ``"{place} · {tot}"`` — the total it settles on, in the mode it
    settles in, so a Gross round does not caption a net figure."""
    from services.low_net_round import low_net_round_summary
    s = low_net_round_summary(round_obj) or {}
    if not float(s.get('entry_fee') or 0):
        return {}                     # no pot: the default gross/net caption
    out = {}
    for r in s.get('results') or []:
        place = _place(r.get('prize_rank') or r.get('rank'))
        tot = r.get('total_net')
        if place and tot is not None:
            out[r['player_id']] = f'{place} · {tot}'
    return out


def stroke_play_stake(round_obj) -> str:
    from services.low_net_round import low_net_round_summary
    fee = float((low_net_round_summary(round_obj) or {}).get('entry_fee') or 0)
    return f'{money(fee)} in' if fee else ''


GAME_SUMMARY['low_net_round'] = stroke_play_rows
GAME_CAPTION['low_net_round'] = stroke_play_captions
GAME_STAKE['low_net_round'] = stroke_play_stake


# ---------------------------------------------------------------------------
# 40 Balls and Hot Seat — group pools
# ---------------------------------------------------------------------------

def _group_rows(round_obj):
    from services.forty_balls import forty_balls_summary
    from services.hot_spot import hot_spot_summary
    for key, fn in (('forty_balls', forty_balls_summary),
                    ('hot_spot', hot_spot_summary)):
        if key in (round_obj.active_games or []):
            s = fn(round_obj) or {}
            yield key, s, (s.get('results') or s.get('standings') or [])


def _group_pool_rows(label):
    def rows(round_obj, entry, names):
        """§4: ``["40 Balls", "Group 2 1st · $40 each"]``.

        The money is stated PER GOLFER ("each") because that is what a golfer
        collects; the group's total is the engine's intermediate figure and
        would read as his.
        """
        for key, s, standings in _group_rows(round_obj):
            if key != entry['game']:
                continue
            paid = [r for r in standings if (r.get('payout') or 0)]
            if not paid:
                return []
            paid.sort(key=lambda r: (r.get('rank') or 99))
            return [[label, ' · '.join(
                f'{r.get("group", "")} {_place(r.get("rank"))} '
                f'{money(r.get("per_person_payout") or 0)} each'
                for r in paid)]]
        return []
    return rows


def _group_pool_captions(image: bool):
    def captions(round_obj, player_ids) -> dict:
        """§4: ``"{place} · group {n}"`` on the ticket, ``"{place} · each"``
        on the preview — where the chip is narrower and the group number is
        the part a reader can do without."""
        from tournament.models import FoursomeMembership
        out = {}
        for key, s, standings in _group_rows(round_obj):
            by_fs = {r.get('foursome_id'): r for r in standings}
            for m in FoursomeMembership.objects.filter(
                    foursome__round=round_obj,
                    player__is_phantom=False):
                row = by_fs.get(m.foursome_id)
                if not row or not row.get('rank'):
                    continue
                place = _place(row['rank'])
                out[m.player_id] = (f'{place} · each' if image
                                    else f'{place} · {row.get("group", "")}')
        return out
    return captions


def _group_pool_stake(key):
    def stake(round_obj) -> str:
        for k, s, _ in _group_rows(round_obj):
            if k == key and float(s.get('entry_fee') or 0):
                return f'{money(s["entry_fee"])} in'
        return ''
    return stake


for _key, _label in (('forty_balls', '40 Balls'), ('hot_spot', 'Hot Seat')):
    GAME_SUMMARY[_key] = _group_pool_rows(_label)
    GAME_CAPTION[_key] = _group_pool_captions(False)
    GAME_IMAGE_CAPTION[_key] = _group_pool_captions(True)
    GAME_STAKE[_key] = _group_pool_stake(_key)


# ---------------------------------------------------------------------------
# Dream Round (Eclectic)
# ---------------------------------------------------------------------------
#
# **Eclectic IS Dream Round** — the website redirects `/games/eclectic` to
# `/games/dream-round`, so §4's "Dream Round · Eclectic" is one game under two
# names, not two pools.
#
# It is a MULTI-ROUND pool on a tournament, so it has no casual-round ledger
# and nothing on the Finish round hook reaches it.  The formatter is
# registered now so the Group C tournament assembler picks it up for free;
# until then it will never be called.

def dream_round_rows(round_obj, entry, names):
    """§4: "the winner and their score"."""
    from services.dream_round import dream_round_standings
    tournament = getattr(round_obj, 'tournament', None)
    if not tournament:
        return []
    rows = []
    for pool in ('net', 'gross'):
        try:
            standings = dream_round_standings(tournament, pool) or []
        except Exception:
            continue
        top = next((r for r in standings if (r.get('rank') or 99) == 1), None)
        if not top:
            continue
        score = top.get('total') or top.get('total_net') or top.get('score')
        rows.append([f'Dream Round {pool.title()}',
                     f'{top.get("name", "")} {score}' if score is not None
                     else top.get('name', '')])
    return rows


GAME_SUMMARY['dream_round'] = dream_round_rows
