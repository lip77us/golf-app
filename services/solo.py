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

**No money.** There is no stake, no press and no settlement row, so none of
`services/wager`, `services/payout` or `services/settlement` is involved.
That is why this file is short: strip the money out of a match-play engine
and what is left is a comparison.
"""
from __future__ import annotations

from games.models import SoloGame
from scoring.handicap import effective_hcp_for, make_strokes_fn
from scoring.models import HoleScore
from services.hole_plan import play_order


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


def _nassau(holes):
    """Front, back and overall, each a match against par.

    Split by POSITION in play order, not by hole number — a shotgun round's
    first nine is the first nine holes the golfer plays.
    """
    front, back = holes[:9], holes[9:18]
    out = {}
    for key, rows in (('front', front), ('back', back), ('overall', holes)):
        up, decided, played = _match_over(rows)
        out[key] = {'up': up, 'decided': decided, 'thru': played,
                    'holes': len(rows)}
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
    }
    if cfg.variant == SoloGame.Variant.NASSAU:
        out['nassau'] = _nassau(holes)
    elif cfg.variant == SoloGame.Variant.MATCH:
        up, decided, played = _match_over(holes)
        out['match'] = {'up': up, 'decided': decided, 'thru': played,
                        'to_play': len(holes) - played}
    return out


def setup_solo(round_obj, *, variant: str, net_percent: int = 100):
    """Create or update the round's solo game."""
    cfg, _ = SoloGame.objects.update_or_create(
        round=round_obj,
        defaults={'variant': variant, 'net_percent': int(net_percent)},
    )
    return cfg
