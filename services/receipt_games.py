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
    GAME_RESULT,
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


# ===========================================================================
# §4 Detail — the long form, web receipt and Round over (never the preview)
# ===========================================================================
#
# One function per game, each registered in `GAME_DETAIL`.  They return
# Sections, and the label NAMES THE GAME, because a round playing two games
# puts two of these on one page.
#
# Every one reads its engine's own summary and formats.  None re-derives a
# result, a margin or a figure — that is the `gross_to_par` rule, and on a
# receipt it is the money.


def _ssec(label, rows):
    """A section, or nothing when there are no rows to put in it."""
    return [{'label': label, 'rows': rows}] if rows else []


def _range(start, end) -> str:
    """"7–11", or "18" when the stretch is one hole.

    Rabbit and Survivor report `holes` as a COUNT, not a list — the window is
    `start_hole`/`end_hole`, and reading the count as a list is a TypeError
    rather than a wrong answer, which is how this was found.
    """
    if start is None:
        return ''
    if end is None or end == start:
        return f'{start}'
    return f'{start}–{end}'


def _place_of(seg) -> str:
    """"· 7–11" for a stretch, or nothing when the engine gives no window."""
    span = _range(seg.get('start_hole'), seg.get('end_hole'))
    return f' · {span}' if span else ''


# ---------------------------------------------------------------------------
# Nassau
# ---------------------------------------------------------------------------

def _nassau_side(summary, which: str) -> str:
    team = (summary.get('teams') or {}).get(which) or []
    return ' & '.join(p.get('short_name') or p.get('name') or '' for p in team)


def _nassau_bet(summary, block: dict) -> str:
    """"Paul & Jim 2 UP", "3&2", "AS" — §4's N UP / N&M / AS / Push."""
    if not block:
        return ''
    result = (block.get('result') or '').lower()
    if result in ('halved', 'push', 'tie', 'all_square', ''):
        # A bet that was played and finished level, versus one still level
        # with holes to come: the receipt is only ever written on a settled
        # round, so this is the first.
        return 'AS' if block.get('holes_played') else ''
    side = _nassau_side(summary, 'team1' if result == 'team1' else 'team2')
    margin = abs(block.get('decided_margin') or block.get('margin') or 0)
    left = block.get('decided_remaining') or 0
    # The close-out notation, same rule as everywhere else: `N&M` only when
    # there were holes left to not play.
    return f'{side} {margin}&{left}' if left else f'{side} {margin} UP'


def nassau_detail(round_obj, entry, names):
    """§4: a row each for Front, Back and Overall, then one per press.

    Claremont adds a points line, because its bottom bet is scored in points
    rather than holes and the figure above it would otherwise be read as the
    whole result.
    """
    from services.nassau import nassau_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        s = nassau_summary(fs)
        if not s:
            continue
        rows = []
        # A nine that is not being played has no bet, and `play_*` is the
        # engine's own answer — a nine-hole round plays one of them.
        for key, played, label in (('front9', 'play_front', 'Front'),
                                   ('back9', 'play_back', 'Back'),
                                   ('overall', 'play_overall', 'Overall')):
            if not s.get(played, True):
                continue
            text = _nassau_bet(s, s.get(key) or {})
            if text:
                rows.append([label, text])
        for pr in (s.get('presses') or []):
            nine = (pr.get('nine') or '').capitalize()
            kind = 'Auto press' if pr.get('press_type') == 'auto' else 'Press'
            rows.append([f'{kind} {pr.get("start_hole")}–{pr.get("end_hole")}',
                         _nassau_bet(s, pr) or 'AS'])
        if (s.get('variant') or '').lower() == 'claremont':
            pts = (s.get('payouts') or {}).get('bottom_total')
            if pts is not None:
                # The bottom bet is two points a hole — low ball and second
                # ball — so it settles in points, not holes.
                rows.append(['Bottom (points)', money(pts, sign=True)])
        out += _ssec(_label(fs, 'Nassau · the bets', multi), rows)
    return out


# ---------------------------------------------------------------------------
# Skins
# ---------------------------------------------------------------------------

#: How many carried holes are named before the run is counted instead.
#: Four is a nine's worth of bad luck, which is the most anybody reads.
_CARRY_NAMED = 4


def skins_detail(round_obj, entry, names):
    """§4's "Skins by hole": `["Hole 7", "Kim ×3 · carried 5, 6"]`, plus a
    "Carried over" row when the round ends on a carry.

    Only holes that were WON get a row — eighteen rows of nothing is not a
    breakdown — and the carried holes are named rather than counted, because
    "carried 5, 6" is checkable against a card and "×3" alone is not.
    """
    from services.skins import skins_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        s = skins_summary(fs)
        if not s:
            continue
        rows, carried = [], []
        # Naming the carried holes is what makes the pot checkable against a
        # card ("carried 5, 6"); naming eleven of them is a paragraph nobody
        # reads, so a long run is counted and anchored instead.
        def _carried(hs):
            return (', '.join(str(h) for h in hs) if len(hs) <= _CARRY_NAMED
                    else f'{len(hs)} holes from {hs[0]}')
        for h in (s.get('holes') or []):
            if h.get('is_killed') or h.get('is_dead'):
                continue
            if not h.get('winner_id'):
                if h.get('is_carry'):
                    carried.append(h['hole'])
                continue
            value = h.get('skins_value') or 1
            text = f'{h.get("winner_short") or ""} ×{value}' if value > 1 \
                else (h.get('winner_short') or '')
            if carried:
                text += ' · carried ' + _carried(carried)
            rows.append([f'Hole {h["hole"]}', text])
            carried = []
        if carried:
            # The round ended on a carry, so that pot was never won.
            rows.append(['Carried over', 'no winner · ' + _carried(carried)])
        out += _ssec(_label(fs, 'Skins by hole', multi), rows)
    return out


# ---------------------------------------------------------------------------
# Rabbit
# ---------------------------------------------------------------------------

def rabbit_detail(round_obj, entry, names):
    """§4: `"Rabbit 2 · 7–11"`, `"Kim · won on 11 · +$15"` or
    `"Loose · carried"`.  The extra rabbit is labelled `Ex`."""
    from services.rabbit import rabbit_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        s = rabbit_summary(fs)
        if not s:
            continue
        rows = []
        for seg in (s.get('segments') or []):
            n = seg.get('index')
            mark = f'Rabbit {n} Ex' if seg.get('is_extra') else f'Rabbit {n}'
            label = mark + _place_of(seg)
            holder = seg.get('holder_short')
            if holder:
                won_on = seg.get('decided_on') or seg.get('end_hole')
                value = f'{holder} · won on {won_on}'
                payout = seg.get('payout')
                if payout:
                    value += f' · {money(payout, sign=True)}'
            elif not seg.get('complete'):
                value = 'Not played'
            else:
                # A loose rabbit pays nobody; with carry on its stake rides
                # into the next one, which is a different sentence from one
                # that simply evaporated on the last rabbit.
                value = 'Loose · carried' if s.get('carry') else 'Loose'
            rows.append([label, value])
        out += _ssec(_label(fs, 'Rabbit · each one', multi), rows)
    return out


# ---------------------------------------------------------------------------
# Survivor
# ---------------------------------------------------------------------------

def survivor_detail(round_obj, entry, names):
    """§4: one row per Survivor — holes, then winner, No blood or Split."""
    from services.survivor import survivor_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        s = survivor_summary(fs)
        if not s:
            continue
        rows = []
        for sv in (s.get('survivors') or []):
            label = f'Survivor {sv.get("index")}' + _place_of(sv)
            outcome = (sv.get('outcome') or '').lower()
            if outcome == 'no_blood':
                value = 'No blood'          # nobody out, so nobody pays
            elif outcome == 'split':
                # **Name the two who shared it.**  A split has no winner, so
                # `winner_short` is null and "Split" on its own was the whole
                # row — the one outcome that told a golfer nothing (Paul,
                # 8 Nov 2026).  The payout is each share, not the pot.
                who = ' & '.join(sv.get('split_shorts') or [])
                value = f'{who} split' if who else 'Split'
                share = sv.get('payout')
                if share:
                    value += f' · {money(share, sign=True)} each'
            elif outcome == 'killed':
                # A Zombie takes the trophy and the money stays put.
                value = f'{sv.get("winner_short") or ""} · killed by ' \
                        f'{sv.get("killed_by_short") or ""} · pays nothing'
            elif sv.get('winner_short'):
                value = sv['winner_short']
                payout = sv.get('payout')
                if payout:
                    value += f' · {money(payout, sign=True)}'
            else:
                value = 'Not played'
            rows.append([label, value])
        out += _ssec(_label(fs, 'Survivor · each one', multi), rows)
    return out


# ---------------------------------------------------------------------------
# Wolf
# ---------------------------------------------------------------------------

def wolf_detail(round_obj, entry, names):
    """§4: one row per hole — the wolf, partner, Lone or Blind, the result.

    **The handoff flags this one itself**: "No settlement mock yet; confirm
    the copy before building."  So this is the plainest reading of that
    sentence, with nothing invented around it.
    """
    from services.wolf import wolf_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        s = wolf_summary(fs)
        if not s:
            continue
        rows = []
        for h in (s.get('holes') or []):
            wolf = h.get('wolf_short') or ''
            if not wolf:
                continue
            decision = (h.get('decision') or '').lower()
            if decision == 'partner' and h.get('partner_short'):
                who = f'{wolf} & {h["partner_short"]}'
            elif decision == 'blind':
                who = f'{wolf} blind'
            elif decision == 'lone':
                who = f'{wolf} lone'
            else:
                who = wolf
            side = (h.get('winning_side') or '').lower()
            if side == 'tie':
                result = 'halved'
            elif side:
                result = 'wolf' if side == 'wolf' else 'field'
            else:
                continue            # not played
            rows.append([f'Hole {h["hole"]}', f'{who} · {result}'])
        out += _ssec(_label(fs, 'Wolf · by hole', multi), rows)
    return out


# ---------------------------------------------------------------------------
# Points 5-3-1
# ---------------------------------------------------------------------------

def points_531_detail(round_obj, entry, names):
    """§4: Out and In points per golfer, plus the settlement mode."""
    from services.points_531 import points_531_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        s = points_531_summary(fs)
        if not s:
            continue
        front, back = {}, {}
        for h in (s.get('holes') or []):
            bucket = front if h['hole'] <= 9 else back
            for e in (h.get('entries') or []):
                pid = e.get('player_id')
                if pid is not None and e.get('points') is not None:
                    bucket[pid] = bucket.get(pid, 0) + (e['points'] or 0)
        rows = []
        for p in (s.get('players') or []):
            pid = p['player_id']
            o, i = front.get(pid, 0), back.get(pid, 0)
            rows.append([p.get('short_name') or p.get('name') or '',
                         f'Out {o:g} · In {i:g} · {(p.get("points") or 0):g}'])
        mode = _points_mode(s)
        if mode:
            rows.append(['Settles', mode])
        out += _ssec(_label(fs, 'Points · out and in', multi), rows)
    return out


def _points_mode(summary) -> str:
    """The three the game is actually played for, in the config's own words."""
    m = summary.get('money') or {}
    if (m.get('payout_style') or '') == 'pool':
        return 'Pool'
    return {'average': 'Against the average',
            'all': 'Everyone above you',
            'first': 'The leader'}.get(m.get('per_point_mode') or '', '')


# ---------------------------------------------------------------------------
# Stroke Play
# ---------------------------------------------------------------------------

def low_net_round_detail(round_obj, entry, names):
    """§4: "the pool (in, places paid)" — the only detail for a pot game.

    It is where the money CAME FROM, which no other row on the receipt says:
    the chips show what each golfer ended with and the pool says what was put
    in to produce it.
    """
    from services.low_net_round import low_net_round_summary
    s = low_net_round_summary(round_obj)
    if not s:
        return []
    fee = s.get('entry_fee') or 0
    entrants = [r for r in (s.get('results') or []) if not r.get('excluded')]
    rows = []
    if fee:
        rows.append(['In', f'{len(entrants)} × {money(fee)} = '
                           f'{money(s.get("purse") or fee * len(entrants))}'])
    for pay in (s.get('payouts') or []):
        # **A place paying nothing is not a prize.**  A configured table can
        # carry a zero — a round played for fun keeps its shape and sets the
        # amounts to nothing — and "1st  $0" under the heading "the pool"
        # describes a pool that does not exist.
        if not float(pay.get('amount') or 0):
            continue
        rows.append([_place(pay.get('place')), money(pay.get('amount') or 0)])
    excluded = [r for r in (s.get('results') or []) if r.get('excluded')]
    if excluded:
        # A golfer can be ranked and visible while unpaid, and nothing else
        # on the receipt would say why his place paid nothing.
        rows.append(['Not paid', ' · '.join(
            r.get('short_name') or r.get('name') or '' for r in excluded)])
    return _ssec('Stroke Play · the pool', rows)


def _label(fs, base: str, multi: bool) -> str:
    """Name the group as well when the round has more than one, or two
    sections carry the same heading and neither says whose.

    Appended rather than inserted, so every game reads the same way round:
    "Skins by hole · group 2", "Nassau · the bets · group 2".
    """
    return f'{base} · group {fs.group_number}' if multi else base


GAME_DETAIL['nassau'] = nassau_detail
GAME_DETAIL['skins'] = skins_detail
GAME_DETAIL['rabbit'] = rabbit_detail
GAME_DETAIL['survivor'] = survivor_detail
GAME_DETAIL['wolf'] = wolf_detail
GAME_DETAIL['points_531'] = points_531_detail
GAME_DETAIL['low_net_round'] = low_net_round_detail


# ---------------------------------------------------------------------------
# Sequoya 3s
# ---------------------------------------------------------------------------

def _seq_side(side) -> str:
    return ' & '.join(p.get('short_name') or p.get('name') or ''
                      for p in (side or []))


def _seq_bet(match, bet) -> str:
    """"RyanL & Paul 1 UP", "AS" — one line for a match or one of its
    presses, from the side that won it."""
    result = bet.get('result') or 0
    if not result:
        return 'AS'
    side = _seq_side(match['side1'] if result == 1 else match['side2'])
    margin = abs(bet.get('margin') or 0)
    return f'{side} {margin} UP' if side else 'AS'


def sequoya_detail(round_obj, entry, names):
    """§4: one row per match with its press results, plus a "Called presses"
    section.

    A press is a NEW BET at the same stake rather than a doubling, so each
    one gets its own row — that is what makes the bet count on the ticket
    ("13 · 5 auto presses, 2 called") add up to something a golfer can check.
    """
    from services.sequoya_threes import sequoya_threes_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        s = sequoya_threes_summary(fs)
        if not s:
            continue
        rows, called = [], []
        for m in (s.get('matches') or []):
            holes = _range(m.get('start_hole'), m.get('end_hole'))
            sides = f'{_seq_side(m.get("side1"))} v {_seq_side(m.get("side2"))}'
            rows.append([f'Match {m.get("index")} · {holes}', sides])
            for bet in (m.get('bets') or []):
                kind = (bet.get('kind') or '').lower()
                if kind == 'match':
                    rows.append(['  result', _seq_bet(m, bet)])
                    continue
                span = _range((bet.get('holes') or [None])[0],
                              (bet.get('holes') or [None])[-1])
                label = ('  auto press' if kind == 'auto_press'
                         else '  press')
                rows.append([f'{label} {span}', _seq_bet(m, bet)])
                if kind != 'auto_press':
                    # §4 asks for these a second time, together: a called
                    # press is a decision somebody made and the argument
                    # afterwards is about those, not the automatic ones.
                    called.append([f'Match {m.get("index")} · {span}',
                                   _seq_bet(m, bet)])
        out += _ssec(_label(fs, 'Sequoya 3s · the matches', multi), rows)
        out += _ssec(_label(fs, 'Called presses', multi), called)
    return out


# ---------------------------------------------------------------------------
# Banker
# ---------------------------------------------------------------------------

def banker_detail(round_obj, entry, names):
    """§4: "Banking · as banker", "Betting · as a player", and "The round".

    Banker is the one game whose golfers each have TWO figures that can
    disagree in sign — a man can bank badly and bet well — so the receipt
    splits them rather than printing a net nobody can check.
    """
    from services.banker import banker_summary
    foursomes = _foursomes(round_obj)
    multi = len(foursomes) > 1
    out = []
    for fs in foursomes:
        s = banker_summary(fs)
        if not s:
            continue
        banking, betting = [], []
        for p in (s.get('players') or []):
            who = p.get('short_name') or p.get('name') or ''
            banking.append([who, money(p.get('banking') or 0, sign=True)])
            betting.append([who, money(p.get('betting') or 0, sign=True)])
        out += _ssec(_label(fs, 'Banking · as banker', multi), banking)
        out += _ssec(_label(fs, 'Betting · as a player', multi), betting)

        rows = []
        settled = s.get('bets_settled')
        if settled:
            rows.append(['Bets settled', str(settled)])
        swings = s.get('biggest_swings') or []
        if swings:
            big = swings[0]
            # The hole everybody remembers, and the only thing on the
            # receipt that says which one it was.
            rows.append([f'Biggest hole · {big.get("hole")}',
                         f'{money(big.get("amount") or 0)} · '
                         f'{big.get("banker") or ""} banking'])
        out += _ssec(_label(fs, 'The round', multi), rows)
    return out


GAME_DETAIL['sequoya_threes'] = sequoya_detail
GAME_DETAIL['banker'] = banker_detail


# ---------------------------------------------------------------------------
# Play for fun — a golfer's RESULT, where a staked round holds his money
# ---------------------------------------------------------------------------
#
# Registered against :data:`GAME_RESULT`.  One entry serves two slots: the
# chip when this is the primary game, and a clause in the caption when it is a
# side game ("88 · net 76 · 4 skins").  They are the same sentence at two
# widths, so they are written once.
#
# **Every figure is read from the engine's own summary**, exactly as the
# money rows above are.  A result that disagreed with the board would be the
# one thing a golfer checks it against.
#
# Not registered: Sixes and Stableford.  Sixes needs each segment's winning
# SIDE rather than its result sentence, and Stableford has no receipt
# formatter at all — both fall through to the rule in `_results`, which is
# today's behaviour rather than a guessed figure.


def _count_result(counts: dict, player_ids, noun: str, plural: str = '') -> dict:
    """"4 skins" / "1 skin" / "no skins", with the leader marked up.

    A golfer who won none has not LOST anything on a round played for
    nothing, so he reads level rather than down — the reasoning in
    :data:`GAME_RESULT`'s own note.
    """
    plural = plural or f'{noun}s'
    best = max([v for v in counts.values()] or [0])
    out = {}
    # Most first, so the dict's own order IS the ranking — which is what the
    # chips and the games row are ordered by.
    for pid in sorted(player_ids, key=lambda p: -(counts.get(p) or 0)):
        n = counts.get(pid) or 0
        if n == 0:
            text = f'no {plural}'
        else:
            text = f'{n:g} {noun if n == 1 else plural}'
        out[pid] = (text, 'up' if n and n == best else 'ev')
    return out


def nassau_results(round_obj, player_ids) -> dict:
    """A golfer's own side's overall match result: "1 UP", "1 DN" or "AS".

    Signed from HIS side, not from team 1 — the chip sits beside his name, so
    a figure he has to mentally reverse is worse than no figure.  The same
    trap `_nine` carries a comment about.
    """
    from services.nassau import nassau_summary
    out = {}
    for fs in _foursomes(round_obj):
        s = nassau_summary(fs) or {}
        teams = s.get('teams') or {}
        overall = s.get('overall') or {}
        if not overall:
            continue
        for which, sign in (('team1', 1), ('team2', -1)):
            text = _nine(overall, sign)
            if not text:
                continue
            tone = 'ev' if text == 'AS' else ('up' if 'UP' in text else 'dn')
            for pl in teams.get(which) or []:
                pid = pl.get('player_id')
                if pid in player_ids:
                    out[pid] = (text, tone)
    return out


def stroke_play_results(round_obj, player_ids) -> dict:
    """His place — "1st", "2nd" — captioned with the total it placed on.

    Read from the SAME ranking the board shows, `prize_rank` first, as
    `stroke_play_captions` does.

    **The caption is this game's own basis, not the round's net**, and that is
    the whole reason `GAME_RESULT` carries one.  A Gross round ranks on gross
    while the default caption sums `HoleScore.net_score` — the round's full
    allowance — so a real round put "1st" over "net 54" and "3rd" over
    "net 53": both figures right, the pair of them unreadable.  This game's
    own caption formatter already promises "the total it settles on, in the
    mode it settles in" and declines when there is no pot, which is exactly
    the case a for-fun round is.

    **"thru N" appears only for a golfer who played fewer holes than the
    field.**  The ranking is on net-to-par, so thirteen holes and eighteen
    compare fairly and legitimately tie — and without the holes said out loud
    a receipt reading "1st on 75" beside "1st on 94" looks like a fault.
    """
    from services.low_net_round import low_net_round_summary
    out = {}
    s = low_net_round_summary(round_obj) or {}
    rows = s.get('results') or []
    gross = (s.get('handicap_mode') or '') == 'gross'
    full = max([(r.get('holes_played') or 0) for r in rows] or [0])
    for r in rows:
        pid = r.get('player_id')
        if pid not in player_ids:
            continue
        rank = r.get('prize_rank') or r.get('rank')
        place = _place(rank)
        if not place:
            continue
        tot = r.get('total_net')
        caption = ''
        if tot is not None:
            caption = f'{tot} gross' if gross else f'net {tot}'
            played = r.get('holes_played') or 0
            if played and full and played < full:
                caption += f' · thru {played}'
        out[pid] = (place, 'up' if int(rank) == 1 else 'ev', caption)
    return out


def points_results(round_obj, player_ids) -> dict:
    """"41 pts" — the figure the game is scored in."""
    from services.points_531 import points_531_summary
    out = {}
    for fs in _foursomes(round_obj):
        vs = _points_vs_target(points_531_summary(fs) or {})
        if not vs:
            continue
        best = max(pts for pts, _v in vs.values())
        for pid, (pts, _v) in vs.items():
            if pid in player_ids:
                out[pid] = (f'{pts:g} pts', 'up' if pts == best else 'ev')
    return out


def wolf_results(round_obj, player_ids) -> dict:
    from services.wolf import wolf_summary
    out = {}
    for fs in _foursomes(round_obj):
        rows = (wolf_summary(fs) or {}).get('players') or []
        pts = {p['player_id']: (p.get('points') or 0) for p in rows}
        if not pts:
            continue
        best = max(pts.values())
        for pid, v in pts.items():
            if pid in player_ids:
                out[pid] = (f'{v:g} pts', 'up' if v == best else 'ev')
    return out


def skins_results(round_obj, player_ids) -> dict:
    """``total_skins``, for the reason `skins_summary_rows` gives: junk is a
    share of the same pot, so the total is what accounts for the round."""
    from services.skins import skins_summary
    counts = {}
    for fs in _foursomes(round_obj):
        for p in (skins_summary(fs) or {}).get('players') or []:
            counts[p['player_id']] = p.get('total_skins') or 0
    return _count_result(counts, player_ids, 'skin')


def rabbit_results(round_obj, player_ids) -> dict:
    from services.rabbit import rabbit_summary
    counts = {}
    for fs in _foursomes(round_obj):
        for sg in (rabbit_summary(fs) or {}).get('segments') or []:
            if sg.get('complete') and sg.get('holder_id'):
                counts[sg['holder_id']] = counts.get(sg['holder_id'], 0) + 1
    return _count_result(counts, player_ids, 'rabbit')


def survivor_results(round_obj, player_ids) -> dict:
    from services.survivor import survivor_summary
    counts = {}
    for fs in _foursomes(round_obj):
        for lg in (survivor_summary(fs) or {}).get('survivors') or []:
            winner = lg.get('winner_id')
            if lg.get('complete') and winner and lg.get('outcome') != 'no_blood':
                counts[winner] = counts.get(winner, 0) + 1
    return _count_result(counts, player_ids, 'Survivor')


GAME_RESULT['nassau'] = nassau_results
GAME_RESULT['low_net_round'] = stroke_play_results
GAME_RESULT['points_531'] = points_results
GAME_RESULT['wolf'] = wolf_results
GAME_RESULT['skins'] = skins_results
GAME_RESULT['rabbit'] = rabbit_results
GAME_RESULT['survivor'] = survivor_results
