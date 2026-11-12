"""
services/solo.py
----------------
One golfer, and the opponent is par.

`handoff-solo-games`: three variants, all of them Net, all of them for fun.

    stroke   net total against par for 18
    nassau   three matches against par — front nine, back nine, all 18
    match    one 18-hole match against par, with a closing score when it is
             decided early

A hole against par, used by nassau and match:

    net under par   won
    net par         halved
    net over par    lost

**Par is not a player.** No phantom, no second card, no membership — every
hole is compared with `hole.par` directly. A phantom would need a handicap, a
tee and a place in every grouping rule in the app, to represent a number the
scorecard already prints.

**No money.** There is no stake and no settlement row, so none of
`services/wager`, `services/payout` or `services/settlement` is involved.
The Nassau may carry auto presses, which here are extra MATCHES rather than
extra bets — a way back into a nine you have lost, costing nothing.
That is why this file is short: strip the money out of a match-play engine
and what is left is a comparison.
"""
from __future__ import annotations

from games.models import SoloGame
from scoring.handicap import effective_hcp_for, make_strokes_fn
from scoring.models import HoleScore
from services.hole_plan import play_order
from services.game_settings import handicap_chip


# ── the golfer ──────────────────────────────────────────────────────────────

def _solo_membership(foursome):
    """The one real golfer. None when the round is not actually solo."""
    members = [m for m in foursome.memberships.select_related('player', 'tee')
               if not m.player.is_phantom]
    return members[0] if len(members) == 1 else None


def strokes_by_hole(foursome, net_percent: int) -> dict:
    """`{hole: strokes}` for the solo golfer at this allowance.

    Full-round allocation by stroke index, as everywhere else. Above 100% the
    golfer simply gets more strokes, and on a course whose index runs 1..18 a
    125% of 12 is 15 — three holes gain a second stroke exactly as a 15
    handicap would. Nothing special is needed for it.
    """
    m = _solo_membership(foursome)
    if m is None or m.tee_id is None:
        return {}
    fn = make_strokes_fn(foursome)
    eff = effective_hcp_for(m, net_percent)
    return {h['number']: fn(eff, m.tee, h['number'])
            for h in (m.tee.holes or [])}


def _config(round_obj):
    return getattr(round_obj, 'solo_game', None)


# ── the walk ────────────────────────────────────────────────────────────────

def _holes(round_obj, foursome, cfg):
    """One row per hole IN PLAY ORDER.

    `{hole, par, stroke_index, gross, strokes, net, to_par, result}` where
    result is 'won' | 'halved' | 'lost' | None (not yet played).
    """
    m = _solo_membership(foursome)
    if m is None:
        return []
    pars, sis = {}, {}
    for h in (m.tee.holes or []) if m.tee_id else []:
        pars[h['number']] = h.get('par')
        sis[h['number']] = h.get('stroke_index')
    alloc = strokes_by_hole(foursome, cfg.net_percent if cfg else 100)
    gross = {r['hole_number']: r['gross_score'] for r in
             HoleScore.objects
             .filter(foursome=foursome, player_id=m.player_id)
             .exclude(gross_score=None)
             .values('hole_number', 'gross_score')}

    out = []
    for hole in play_order(round_obj, foursome):
        par = pars.get(hole)
        g = gross.get(hole)
        sh = alloc.get(hole, 0)
        net = None if g is None else g - sh
        result = None
        if net is not None and par is not None:
            result = 'won' if net < par else ('halved' if net == par else 'lost')
        out.append({
            'hole': hole, 'par': par, 'stroke_index': sis.get(hole),
            'gross': g, 'strokes': sh, 'net': net,
            'to_par': None if (net is None or par is None) else net - par,
            'result': result,
        })
    return out


# ── the three readings ──────────────────────────────────────────────────────

def _stroke(holes):
    played = [h for h in holes if h['to_par'] is not None]
    return {
        'to_par': sum(h['to_par'] for h in played) if played else 0,
        'net_total': sum(h['net'] for h in played) if played else 0,
        'thru': len(played),
    }


def _match_over(rows):
    """`(up, result)` for a list of hole rows — up is from the GOLFER's side.

    `result` is the closing score once the match cannot be caught ('3&2'),
    else None. A solo match is decided by the same arithmetic as any other:
    more holes up than there are left to play.
    """
    up = 0
    played = 0
    decided = None
    total = len(rows)
    for i, h in enumerate(rows):
        if h['result'] is None:
            continue
        played += 1
        if h['result'] == 'won':
            up += 1
        elif h['result'] == 'lost':
            up -= 1
        remaining = total - (i + 1)
        if decided is None and abs(up) > remaining:
            # "3&2" — the margin, and the holes that were left.
            decided = f'{abs(up)}&{remaining}' if remaining else f'{abs(up)} up'
    return up, decided, played


#: Signed, and read from the GOLFER's side: −2 is him two down and pressing,
#: +2 is par two down and pressing back. The same set `services/nassau`
#: fires on, which is the point — see `_presses`.
_AUTO_PRESS_LEVELS = (-2, -4, -6, -8, 2, 4, 6, 8)


def _presses(rows):
    """Auto presses for ONE nine, from the golfer's side.

    One fires when either side goes 2, 4, 6 or 8 down — each level once — and
    runs from the NEXT hole to the end of that nine, scored as its own little
    match. Same levels and the same next-hole start as a real Nassau
    (`services/nassau.AUTO_TOP_THRESHOLDS`), so a golfer who presses in his
    Saturday game does not have to learn a second rule here.

    **Par presses back.** The first version fired one way only, on the
    argument that par has no agency — which is true of par as a NUMBER and
    false of what this game is for. Paul (Oct 2026): the point is to simulate
    a full match against a scratch player who shoots par, and a scratch
    player two down presses. One-directional presses make that opponent a
    man who never fights back, which is the one thing a practice match should
    not teach.

    `pressed_by` says whose it is. The margin is read from the golfer's side
    either way — `up` is his — so the owner is not needed to score it; it is
    needed to say what happened, and "Par pressed" is the half of this that
    makes the simulation feel like a match.

    Presses belong to the two NINES only, never to the overall bet — again as
    in the real game. Nothing is stored: a press is derived from the holes on
    every read, so correcting a score on the 3rd un-fires a press that the
    corrected score no longer earns.
    """
    out, fired, up = [], set(), 0
    for i, h in enumerate(rows):
        if h['result'] is None:
            continue
        up += 1 if h['result'] == 'won' else (-1 if h['result'] == 'lost' else 0)
        remaining = rows[i + 1:]
        # Nothing to press on the last hole of the nine.
        if not remaining or up not in _AUTO_PRESS_LEVELS or up in fired:
            continue
        fired.add(up)
        p_up, p_decided, p_thru = _match_over(remaining)
        out.append({
            'index': len(out) + 1,
            # The side that was DOWN when it fired, which is the side that
            # pressed — a negative margin is the golfer's.
            'pressed_by': 'you' if up < 0 else 'par',
            'trigger_hole': h['hole'],
            'start': remaining[0]['hole'],
            'end': remaining[-1]['hole'],
            'holes': len(remaining),
            'up': p_up, 'decided': p_decided, 'thru': p_thru,
        })
    return out


def _nassau(holes, auto_press: bool = False):
    """Front, back and overall, each a match against par.

    Split by POSITION in play order, not by hole number — a shotgun round's
    first nine is the first nine holes the golfer plays.
    """
    front, back = holes[:9], holes[9:18]
    out = {'auto_press': bool(auto_press)}
    for key, rows in (('front', front), ('back', back), ('overall', holes)):
        up, decided, played = _match_over(rows)
        out[key] = {'up': up, 'decided': decided, 'thru': played,
                    'holes': len(rows),
                    'presses': _presses(rows) if (
                        auto_press and key != 'overall') else []}
    return out


# ── summary ─────────────────────────────────────────────────────────────────

def solo_summary(round_obj) -> dict:
    """The board for a solo round, or `{'configured': False}`."""
    cfg = _config(round_obj)
    if cfg is None:
        return {'configured': False}
    foursome = round_obj.foursomes.first()
    if foursome is None:
        return {'configured': False}
    m = _solo_membership(foursome)
    holes = _holes(round_obj, foursome, cfg)

    out = {
        'configured': True,
        'variant': cfg.variant,
        'label': cfg.get_variant_display(),
        'net_percent': cfg.net_percent,
        'player_id': m.player_id if m else None,
        'player_name': m.player.name if m else '',
        'course_handicap': m.course_handicap if m else None,
        'tee_name': (m.tee.tee_name if m and m.tee_id else ''),
        'holes': holes,
        'stroke': _stroke(holes),
        # No money anywhere: a solo round has nothing to settle, which is why
        # there is no entry fee, payout table or settlement block here.
        'for_fun': True,
        # Stated HERE rather than left to `game_settings.attach`, because
        # Solo has no `handicap_mode` to read generically — it is always Net
        # by design. `always_percent` is the point: the allowance is the only
        # setting this game has, and 100% is as worth saying as 110%.
        'settings': [c for c in [
            handicap_chip('net', cfg.net_percent, always_percent=True)
        ] if c],
    }
    if cfg.variant == SoloGame.Variant.NASSAU:
        out['auto_press'] = cfg.auto_press
        out['nassau'] = _nassau(holes, auto_press=cfg.auto_press)
    elif cfg.variant == SoloGame.Variant.MATCH:
        up, decided, played = _match_over(holes)
        out['match'] = {'up': up, 'decided': decided, 'thru': played,
                        'to_play': len(holes) - played}
    return out


def setup_solo(round_obj, *, variant: str, net_percent: int = 100,
               auto_press: bool = False):
    """Create or update the round's solo game.

    `auto_press` is stored whatever the variant, and read only by the Nassau
    — a golfer who switches from Nassau to Match Play and back should find
    his press switch where he left it.
    """
    cfg, _ = SoloGame.objects.update_or_create(
        round=round_obj,
        defaults={'variant': variant, 'net_percent': int(net_percent),
                  'auto_press': bool(auto_press)},
    )
    # Drop the Round's cached `solo_game`. Creating one populates that cache,
    # so on a SECOND setup the caller is left holding the old config — and
    # the setup POST calls `solo_summary(round_obj)` on this very instance
    # immediately afterwards, which would answer with the settings the golfer
    # just replaced.
    round_obj._state.fields_cache.pop('solo_game', None)
    return cfg


# ── score-entry card — `~/Downloads/handoff-solo-score-entry` ───────────────

_NET_WORD = {-3: 'Net albatross', -2: 'Net eagle', -1: 'Net birdie',
             0: 'Net par', 1: 'Net bogey', 2: 'Net double'}


def _asof(rows, pos):
    """The golfer's holes with everything after position `pos` unplayed —
    which is what a tray reopened on the 4th must report."""
    return [h if i <= pos else {**h, 'gross': None, 'net': None,
                                'to_par': None, 'result': None}
            for i, h in enumerate(rows)]


def _signed(v: int) -> str:
    return 'E' if v == 0 else (f'+{v}' if v > 0 else f'−{abs(v)}')


def _bet_chip(label, up, decided, thru, holes, golfer):
    """One bet against par: live, or final once it is decided or played out.
    `leader` is 1 (the golfer), 2 (par) or None."""
    final = decided is not None or thru == holes
    if thru == 0 and not final:
        return None
    leader = 1 if up > 0 else (2 if up < 0 else None)
    who = golfer if up > 0 else 'Par'
    if final:
        if up == 0:
            text = 'Push'
        elif decided and '&' in decided:
            text = f'{who} {decided}'
        else:
            text = f'{who} {abs(up)} UP'
        return {'label': label, 'text': text, 'state': 'final',
                'leader': leader}
    text = 'AS' if up == 0 else f'{who} {abs(up)} UP'
    return {'label': label, 'text': text, 'state': 'live', 'leader': leader}


def solo_hole_card(foursome, hole: int) -> dict:
    """Everything the solo score-entry screen draws for ONE hole.

    **It renders `solo_summary`'s walk and decides no golf**: a hole against
    par is net under = won, net par = halved, net over = lost, and the
    matches, closing scores and auto presses are `_match_over` / `_presses`.
    What this adds is the cut (the round AS OF this hole) and the sentences.
    Returns `{}` when the round is not a configured solo round.
    """
    rnd = foursome.round
    cfg = _config(rnd)
    m = _solo_membership(foursome)
    if cfg is None or m is None:
        return {}
    rows = _holes(rnd, foursome, cfg)
    order = [r['hole'] for r in rows]
    if hole not in order:
        return {}
    pos = order.index(hole)
    row = rows[pos]
    cur = _asof(rows, pos)
    first = (m.player.name or '').split(' ')[0] or 'You'
    variant = cfg.variant
    strokes_total = sum(r['strokes'] for r in rows)
    complete = row['gross'] is not None
    last = pos == len(rows) - 1
    round_over = complete and last

    card = {
        'hole': hole, 'par': row['par'], 'stroke_index': row['stroke_index'],
        'thru': pos + 1, 'variant': variant,
        'title': {'stroke': 'Stroke Play', 'nassau': 'Nassau',
                  'match': 'Match Play'}.get(variant, 'Solo'),
        'net_percent': cfg.net_percent,
        'golfer': {
            'player_id': m.player_id, 'name': m.player.name, 'first': first,
            'course_handicap': m.course_handicap, 'gross': row['gross'],
            'net': row['net'], 'strokes': row['strokes'],
            'strokes_total': strokes_total,
            'si_range': (f'SI 1–{strokes_total}'
                         if 0 < strokes_total <= 18 else ''),
        },
        'hole_complete': complete, 'round_over': round_over,
        'next_hole': order[pos + 1] if pos + 1 < len(order) else None,
        'result': row['result'],
    }

    if variant == 'stroke':
        s = _stroke(cur)
        par_total = sum(r['par'] or 0 for r in rows)
        gross_total = sum(r['gross'] for r in cur if r['gross'] is not None)
        card['stroke'] = {
            'word': (_NET_WORD.get(row['to_par'], 'Net ' + _signed(
                row['to_par'])) if row['to_par'] is not None else ''),
            'to_par': s['to_par'], 'to_par_text': _signed(s['to_par']),
            'gross_total': gross_total, 'net_total': s['net_total'],
            'thru': s['thru'], 'par_total': par_total,
        }
        if round_over:
            card['final'] = {
                'line': f"Net total {_signed(s['to_par'])}",
                'sub': (f"gross {gross_total} · net {s['net_total']}"
                        f" · par {par_total}"),
                'card': f"Net {s['net_total']} · {_signed(s['to_par'])}",
                'note': ('For fun: nothing to settle. The card goes to the '
                         'round history.'),
            }
    elif variant == 'nassau':
        nas = _nassau(cur, auto_press=cfg.auto_press)
        chips = []
        for key, label in (('front', 'Front'), ('back', 'Back'),
                           ('overall', 'Overall')):
            b = nas[key]
            chip = _bet_chip(label, b['up'], b['decided'], b['thru'],
                             b['holes'], first)
            if chip is None:
                start = order[9] if key == 'back' and len(order) > 9 else None
                chip = {'label': label,
                        'text': (f'{label} starts {start}' if start
                                 else f'{label} not started'),
                        'state': 'pending', 'leader': None}
            else:
                chip['text'] = f"{label} {chip['text']}"
            chips.append(chip)
            for p in b['presses']:
                started = hole >= p['start']
                chips.append({
                    'label': f"P{p['index']}",
                    'text': (f"P{p['index']} " + (
                        ('Push' if p['up'] == 0 else
                         f"{first if p['up'] > 0 else 'Par'} {abs(p['up'])} UP")
                        if started else f"starts {p['start']}")),
                    'state': ('pending' if not started else
                              'final' if p['decided'] or p['thru'] == p['holes']
                              else 'live'),
                    'leader': (1 if p['up'] > 0 else 2 if p['up'] < 0
                               else None) if started else None,
                })
        card['nassau'] = {'chips': chips}
        if round_over:
            res = []
            for key in ('front', 'back', 'overall'):
                u = nas[key]['up']
                res.append('won' if u > 0 else 'lost' if u < 0 else 'halved')
            won, lost = res.count('won'), res.count('lost')
            card['final'] = {
                'line': f'{won} won · {lost} lost',
                'sub': (f'Against par: front {res[0]}, back {res[1]}, '
                        f'overall {res[2]}.'),
                'note': 'For fun: nothing to settle.',
            }
    elif variant == 'match':
        up, decided, thru = _match_over(cur)
        decided_at = None
        if decided:
            # The hole the match was decided on: the first hole where the
            # margin outran what was left.
            u = 0
            for i, r in enumerate(cur):
                if r['result'] is None:
                    continue
                u += 1 if r['result'] == 'won' else (
                    -1 if r['result'] == 'lost' else 0)
                if abs(u) > len(cur) - (i + 1):
                    decided_at = r['hole']
                    break
        tiles = []
        for i, r in enumerate(rows):
            if r['hole'] > hole and i > pos:
                st = 'x'
            else:
                st = {'won': 'w', 'lost': 'l', 'halved': 'h'}.get(
                    cur[i]['result'], 'x')
            after = decided_at is not None and order.index(
                r['hole']) > order.index(decided_at)
            tiles.append({'hole': r['hole'], 'state': st,
                          'dimmed': bool(after)})
        who = first if up > 0 else 'Par'
        std = ('All square' if up == 0 else
               f'{who} wins {decided}' if decided else
               f'{who} {abs(up)} UP')
        card['match'] = {
            'up': up, 'standing': std,
            'short': 'AS' if up == 0 else f'{abs(up)} UP',
            'leader': 1 if up > 0 else (2 if up < 0 else None),
            'decided': decided, 'decided_on': decided_at,
            'thru': thru, 'to_play': len(rows) - thru,
            'tiles': tiles,
            'over_line': (f'Decided on {decided_at} · holes '
                          f"{order[order.index(decided_at) + 1]}–"
                          f'{order[-1]} played out for the card')
                         if decided and decided_at != order[-1] else '',
            'after_close': bool(decided_at is not None and pos
                                > order.index(decided_at)),
            'after_line': (f'MATCH {first if up > 0 else "Par"} won '
                           f'{decided} · hole {hole} is played out')
                          if decided and decided_at is not None
                          and pos > order.index(decided_at) else '',
        }
    return card
