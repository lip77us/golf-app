"""
scoring/handicap.py
-------------------
Central helpers for producing a per-player, per-hole score index that any
game calculator can consume.

Different games (Sixes, Nassau, Skins, Match Play, etc.) all need the same
thing from scoring: for every player, for every hole, what single number
should we compare against the other players?  That number depends on the
handicap mode the user picked for the match:

    net          — gross - handicap_strokes (current default)
    gross        — gross score, no strokes
    strokes_off  — reserved for a future mode where the low-handicap player
                   plays to 0 and everyone else gets (own_HCP - low_HCP)
                   strokes allocated by hole stroke index.  Not implemented
                   yet; falls back to net for now.

Exposed API
~~~~~~~~~~~
    build_score_index(foursome,
                      handicap_mode='net',
                      net_percent=100,
                      include_phantom=False)
        Returns a dict shaped like:
            { player_id: { hole_number: score_to_use } }

Design notes
~~~~~~~~~~~~
* For the common 'net' mode at 100% we re-use the already-computed
  HoleScore.net_score field for speed.
* For any other net percentage we re-derive per-hole strokes from
  FoursomeMembership.playing_handicap × net_percent / 100 and subtract
  from the gross score.  The re-derivation uses the same stroke
  allocation rule as FoursomeMembership.handicap_strokes_on_hole:
    full_strokes = effective_hcp // 18
    remainder    = effective_hcp %  18
    extra        = 1 if stroke_index <= remainder else 0
  This keeps the UI's per-hole stroke dots in sync with what the
  calculator actually used.
* Holes with no gross_score on file are simply omitted from the returned
  dict; calculators already treat "missing hole for a player" as
  "match not yet scorable", so no behavior change there.
"""

from core.models import HandicapMode
from scoring.models import HoleScore


def _effective_hcp(playing_handicap: int, net_percent: int) -> int:
    """Scale playing_handicap by net_percent (%) and round to an int."""
    if net_percent == 100:
        return playing_handicap
    # Round-half-up to keep things predictable (e.g. 90% of 19 = 17.1 → 17).
    return int(round(playing_handicap * (net_percent / 100.0)))


def _strokes_on_hole(effective_hcp: int, stroke_index: int) -> int:
    """Allocate effective_hcp strokes using the hole's stroke index."""
    if effective_hcp <= 0:
        return 0
    full = effective_hcp // 18
    rem  = effective_hcp %  18
    extra = 1 if stroke_index <= rem else 0
    return full + extra


def build_score_index(
    foursome,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    include_phantom: bool = False,
) -> dict:
    """
    Return {player_id: {hole_number: score}} for all hole scores on file
    in *foursome*, adjusted per the requested handicap mode.

    Parameters
    ----------
    foursome        : tournament.models.Foursome instance
    handicap_mode   : 'net' | 'gross' | 'strokes_off'
    net_percent     : integer percent applied to playing_handicap when
                      handicap_mode='net'.  Ignored for 'gross'.
    include_phantom : if False (default) phantom player scores are skipped,
                      matching the behavior of services/sixes.py today.
    """
    base_qs = HoleScore.objects.filter(foursome=foursome)
    if not include_phantom:
        base_qs = base_qs.filter(player__is_phantom=False)

    # -- Gross: trivial -----------------------------------------------------
    if handicap_mode == HandicapMode.GROSS:
        rows = base_qs.exclude(gross_score=None).values(
            'player_id', 'hole_number', 'gross_score'
        )
        index: dict = {}
        for r in rows:
            index.setdefault(r['player_id'], {})[r['hole_number']] = r['gross_score']
        return index

    # -- Net @ 100% (or STROKES_OFF fallback): use stored net_score --------
    # STROKES_OFF isn't implemented yet; falling back to full-net means
    # any calculator that asks for it still works — we just don't yet do
    # the "low player plays to 0" adjustment.  A future change here will
    # re-derive strokes as (own_hcp - low_hcp) before allocating by SI.
    if handicap_mode != HandicapMode.NET or net_percent == 100:
        rows = base_qs.exclude(net_score=None).values(
            'player_id', 'hole_number', 'net_score'
        )
        index = {}
        for r in rows:
            index.setdefault(r['player_id'], {})[r['hole_number']] = r['net_score']
        return index

    # -- Net at a custom percentage: re-derive strokes per hole ------------
    # We need each player's playing_handicap and each player's tee so we
    # can look up the stroke index for every hole.  Pull memberships once.
    memberships = (
        foursome.memberships
        .select_related('player', 'tee')
        .all()
    )
    membership_by_player = {m.player_id: m for m in memberships}

    rows = base_qs.exclude(gross_score=None).values(
        'player_id', 'hole_number', 'gross_score'
    )
    index = {}
    for r in rows:
        m = membership_by_player.get(r['player_id'])
        if m is None or m.tee_id is None:
            # Shouldn't normally happen, but don't crash if it does.
            continue
        effective = _effective_hcp(m.playing_handicap, net_percent)
        stroke_index = m.tee.hole(r['hole_number']).get('stroke_index', 18)
        strokes = _strokes_on_hole(effective, stroke_index)
        adjusted = r['gross_score'] - strokes
        index.setdefault(r['player_id'], {})[r['hole_number']] = adjusted
    return index
