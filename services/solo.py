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
