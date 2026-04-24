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
    strokes_off  — the low-handicap player in the foursome plays to 0 and
                   everyone else gets (own_HCP - low_HCP) strokes allocated
                   to the hardest holes.  For Sixes, the strokes are *spread*
                   across the three standard 6-hole matches so every match
                   is handicapped on its own; extra (tiebreak) matches use a
                   plain course-wide SI threshold.

Exposed API
~~~~~~~~~~~
    build_score_index(foursome,
                      handicap_mode='net',
                      net_percent=100,
                      segments=None,
                      include_phantom=False)
        Returns a dict shaped like:
            { player_id: { hole_number: score_to_use } }

        `segments` is only consulted for the 'strokes_off' mode.  Callers
        that want the Sixes SO-spreading rule must pass an iterable of
        segment-like objects (see `_sixes_so_plan` for the required shape).
        If `segments` is missing when SO is requested, the function falls
        back to full-net so older callers keep working.

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
* Strokes-Off with Sixes spreading: a player with SO=N strokes receives
  ceil(N/3) or floor(N/3) per standard segment, distributed so the first
  (N % 3) segments get the extra.  Within a segment, strokes are allocated
  to the hardest holes (lowest SI) in that SEGMENT'S OWN POTENTIAL RANGE
  — if match 1 ends early and match 2 shifts to e.g. 5-10, match 2's
  strokes are allocated among 5-10 (not canonical 7-12).  If a match ends
  early and a planned stroke was on an unreached hole, that stroke dies.
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


# ---------------------------------------------------------------------------
# Strokes-Off helpers (Sixes-style spreading across three segments)
# ---------------------------------------------------------------------------

def _strokes_for_segment_index(player_so: int, segment_idx: int) -> int:
    """
    How many strokes this player gets in the segment at `segment_idx`
    (0=first match, 1=second, 2=third) under the Sixes SO-spreading rule.

    floor(SO/3) base per segment, plus 1 extra for the first (SO % 3)
    segments — so 1 stroke → [1,0,0], 5 strokes → [2,2,1], 7 → [3,2,2].
    """
    if player_so <= 0:
        return 0
    base = player_so // 3
    rem  = player_so %  3
    return base + (1 if segment_idx < rem else 0)


def _allocate_segment_strokes(strokes_this_seg: int,
                              holes_with_si: list) -> dict:
    """
    Distribute `strokes_this_seg` strokes across the given holes, giving
    strokes first to the hardest (lowest stroke-index) hole and cycling
    back to the hardest when strokes > segment size.

    Parameters
    ----------
    strokes_this_seg : total strokes this player receives in this segment
    holes_with_si    : list of (hole_number, stroke_index) tuples — the
                       hole range this segment covers.

    Returns
    -------
    {hole_number: strokes} for any hole that receives 1 or more strokes.
    """
    if strokes_this_seg <= 0 or not holes_with_si:
        return {}

    # Sort hardest-first (lowest SI); tiebreak by hole order for determinism.
    ranked = sorted(holes_with_si, key=lambda t: (t[1], t[0]))
    seg_size = len(ranked)

    if strokes_this_seg <= seg_size:
        return {h: 1 for (h, _si) in ranked[:strokes_this_seg]}

    # Rare: more strokes than holes in the segment.  Everyone gets 1, then
    # the extras go back to the hardest holes.
    extras = strokes_this_seg - seg_size
    out = {h: 1 for (h, _si) in ranked}
    for (h, _si) in ranked[:extras]:
        out[h] += 1
    return out


def _sixes_so_plan(segments, memberships) -> dict:
    """
    Build a {player_id: {hole_number: strokes}} plan for the Sixes SO mode.

    `segments` is an iterable of objects with:
        .segment_number (1, 2, 3, 4, ...)
        .is_extra (bool)
        .start_hole, .end_hole (ints)
    `memberships` is an iterable of FoursomeMembership with
        .player_id, .playing_handicap, .tee (may be None).

    Rules
    -----
    * Low playing_handicap in the foursome plays to 0; everyone else has
      SO = own_playing_handicap - low.
    * For the three standard (is_extra=False) matches, ordered by
      segment_number, strokes are spread per `_strokes_for_segment_index`
      and allocated to the hardest holes inside that SEGMENT'S OWN
      POTENTIAL RANGE (seg.start_hole..seg.end_hole).  If match 1 ends
      early and match 2 shifts to e.g. 5-10, match 2's strokes are
      allocated among 5-10.  If a stroke is planned on a hole the match
      never actually reached (because it ended early at some earlier
      hole), that stroke dies.
    * For extra (is_extra=True) segments, a player with SO=N gets one
      stroke on any hole in the segment whose stroke_index <= N.  (SO > 18
      would cycle but that's vanishingly rare so we don't try.)
    """
    ms = list(memberships)
    if not ms:
        return {}

    phcps = [m.playing_handicap for m in ms]
    low = min(phcps) if phcps else 0
    player_so = {m.player_id: max(0, m.playing_handicap - low) for m in ms}

    # Segments ordered by segment_number (1..3 standard, then extras).
    by_num = sorted(segments, key=lambda s: s.segment_number)
    standard = [s for s in by_num if not s.is_extra]
    extras   = [s for s in by_num if s.is_extra]

    # Every hole currently living inside an is_extra segment — those got
    # pushed out of a standard match by an early finish.
    extra_holes = set()
    for seg in extras:
        for h in range(seg.start_hole, seg.end_hole + 1):
            extra_holes.add(h)

    # For each segment, the last hole actually played is one less than the
    # start of the next segment (standard or extra).  If a segment is the
    # final one and there's no next segment, it ran to hole 18.  A stroke
    # planned past this boundary died because the match never got that far.
    actual_end_by_seg_num: dict = {}
    for i, s in enumerate(by_num):
        actual_end_by_seg_num[s.segment_number] = (
            by_num[i + 1].start_hole - 1 if i + 1 < len(by_num) else 18
        )

    plan: dict = {}

    for m in ms:
        so = player_so[m.player_id]
        if so <= 0 or m.tee_id is None:
            continue
        p_plan = plan.setdefault(m.player_id, {})

        # Standard segments: spread strokes + hardest-in-segment-range.
        # Allocate across the segment's own potential range, then drop any
        # stroke planned past the point the match actually reached.
        for idx, seg in enumerate(standard):
            strokes_seg = _strokes_for_segment_index(so, idx)
            if strokes_seg <= 0:
                continue
            actual_end = actual_end_by_seg_num.get(
                seg.segment_number, seg.end_hole
            )
            holes_with_si = [
                (h, m.tee.hole(h).get('stroke_index', 18))
                for h in range(seg.start_hole, seg.end_hole + 1)
            ]
            for h, s in _allocate_segment_strokes(strokes_seg, holes_with_si).items():
                if h > actual_end:
                    continue  # stroke dies — match ended before reaching h
                p_plan[h] = s

        # Extra segments: SI threshold at the course-wide SO number.
        # A player with SO=N gets a stroke on any extra hole whose stroke
        # index is <= N.
        for h in extra_holes:
            si = m.tee.hole(h).get('stroke_index', 18)
            if si <= so:
                p_plan[h] = 1  # (SO > 18 cycling is ignored)

    return plan


def build_score_index(
    foursome,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    segments=None,
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

    # -- Strokes-Off (Sixes-style spreading) ------------------------------
    # Requires segments so we know where each match starts/ends and which
    # one is an "extra" (tiebreak) segment.  If the caller didn't pass any,
    # fall back to full-net behavior so older callers keep working.
    if handicap_mode == HandicapMode.STROKES_OFF and segments:
        memberships = (
            foursome.memberships
            .select_related('player', 'tee')
            .all()
        )
        if not include_phantom:
            memberships = [m for m in memberships if not m.player.is_phantom]
        plan = _sixes_so_plan(segments, memberships)

        rows = base_qs.exclude(gross_score=None).values(
            'player_id', 'hole_number', 'gross_score'
        )
        index = {}
        for r in rows:
            strokes = plan.get(r['player_id'], {}).get(r['hole_number'], 0)
            index.setdefault(r['player_id'], {})[r['hole_number']] = (
                r['gross_score'] - strokes
            )
        return index

    # -- Net @ 100% (or STROKES_OFF fallback when no segments): use stored --
    # net_score.  STROKES_OFF without segment info can't do the spreading
    # math so we degrade to full-net — keeps life easy for callers that
    # haven't wired segments through yet.
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
