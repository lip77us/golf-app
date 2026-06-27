"""
services/triple_cup.py
----------------------
One-Round Ryder Cup ("Triple Cup") calculator.

Format
~~~~~~
A foursome plays a single 18-hole match split into three 6-hole segments:

    Holes  1– 6   Fourball   — best-ball match play
    Holes  7–12   Foursomes  — alternate-shot match play (50%L + 50%H by default)
    Holes 13–18   Singles    — head-to-head match play (2 matches in 2v2)

Per-match cup scoring — each decided match awards 1 point_value to the
winner, halves split.  Match counts by group size:

    2v2 (canonical)   4 matches (1 fourball + 1 foursomes + 2 singles) → 4 pv
    2v1 (solo)        4 matches  (fourball uses a phantom partner for solo,
                                  foursomes = solo plays every shot,
                                  singles = solo plays both opponents)   → 4 pv
    1v1               3 matches  (every segment played as singles)        → 3 pv

Public API
~~~~~~~~~~
    setup_triple_cup(foursome, team1_ids, team2_ids, *, handicap_mode='net',
                     net_percent=100, alt_shot_low_pct=50,
                     alt_shot_high_pct=50, phantom_score_mode='net_par')
    calculate_triple_cup(foursome)
    triple_cup_summary(foursome)

The setup takes the two sides as lists of real player IDs; the rest of
the schedule (which segment uses which players, how many matches, etc.)
is derived from those lists.  Phantoms in the foursome's membership are
ignored throughout — the 2v1 fourball synthesises its phantom score
arithmetically from the tee's par instead of relying on a Player row.
"""

from __future__ import annotations

import math

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import (
    TripleCupGame,
    TripleCupMatch,
    TripleCupTeam,
    TripleCupHoleResult,
)
from scoring.handicap import build_score_index
from scoring.models import HoleScore
from scoring.phantom import (
    CROSS_FOURSOME_ALGORITHM_ID,
    setup_cross_foursome_phantom,
)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SEGMENT_RANGES = [
    ('fourball',  1,   6),
    ('foursomes', 7,  12),
    ('singles',   13, 18),
]


def _is_cup_round(round_obj) -> bool:
    """True when the round has a RyderCupRoundConfig attached.  Cup
    rounds always have ≥1 sibling foursome on the opposing team,
    which is required for cross-foursome donor selection in 2v1."""
    try:
        _ = round_obj.ryder_cup_config
        return True
    except Exception:
        return False


def _solo_tournament_team(foursome, team1_ids: list[int], team2_ids: list[int]):
    """Return the TournamentTeam the solo player belongs to.  Used to
    find cross-foursome donors for the phantom fourball partner."""
    solo_pid = team1_ids[0] if len(team1_ids) == 1 else team2_ids[0]
    from tournament.models import TournamentTeam
    rc = foursome.round.ryder_cup_config
    teams = TournamentTeam.objects.filter(
        tournament=rc.tournament,
        players__id=solo_pid,
    ).distinct()
    return teams.first()


def _whs_so_net_index(
    foursome,
    game,
    members_by_pid: dict,
    gross_index: dict,
    *,
    include_phantom: bool = False,
    fourball_holes: set | None = None,
) -> dict:
    """Build {player_id: {hole: net}} for SO mode the Triple Cup way:
    each player's SO = (their playing handicap − foursome low) ×
    net_percent/100, allocated by plain WHS (any hole with SI ≤ SO
    gets a stroke, with a second cycle for SO > 18).  Net = gross −
    strokes.  Foursome low plays scratch.

    Cross-foursome donor phantom (2v1, the redesign): on each *fourball_holes*
    hole the phantom plays AS that hole's rotating donor, so the hole is scored
    as a real 4-some {solo, that hole's donor, opp1, opp2}.  The low is
    recomputed per hole as min(real low, donor index) and EVERY player —
    including the phantom (at the donor's index) — gets (index − low) strokes.
    Consequence: when a donor is the lowest, the real players pick up an extra
    stroke on that hole.

    Other phantom modes (net_par synthesis, or a pre-redesign config with no
    per-donor handicaps): the legacy scratch-phantom collapse — on fourball
    holes the phantom is the low (0) and every real player plays to full HC.

    Non-phantom (4-player) groups: low is the lowest REAL player on every hole.
    """
    real_hcps = [m.playing_handicap for m in members_by_pid.values()
                 if m.playing_handicap is not None and not m.player.is_phantom]
    low_real = min(real_hcps) if real_hcps else 0

    has_phantom  = any(m.player.is_phantom for m in members_by_pid.values())
    fb_holes_set = fourball_holes or set()

    # Pull this hole's donor index for a cross-foursome phantom so the low
    # (and everyone's strokes) recompute hole-by-hole.  Falls back to the
    # legacy scratch collapse when there's no per-donor data (net_par phantom
    # or a config minted before the redesign).
    donor_hcp_by_hole: dict = {}
    phantom_pid = None
    if has_phantom and fb_holes_set:
        phantom_m = next((m for m in members_by_pid.values()
                          if m.player.is_phantom), None)
        if phantom_m is not None:
            phantom_pid = phantom_m.player_id
            if phantom_m.phantom_algorithm == CROSS_FOURSOME_ALGORITHM_ID:
                from scoring.phantom import get_algorithm
                algo = get_algorithm(phantom_m.phantom_algorithm)
                cfg  = phantom_m.phantom_config or {}
                for h in fb_holes_set:
                    dh = algo.donor_handicap(h, cfg)
                    if dh is not None:
                        donor_hcp_by_hole[h] = dh

    use_scratch_phantom = has_phantom and bool(fb_holes_set) and not donor_hcp_by_hole

    out: dict = {}
    for pid, holes in gross_index.items():
        m = members_by_pid.get(pid)
        if m is None or m.tee_id is None:
            continue
        if m.player.is_phantom and not include_phantom:
            continue
        base_hcp = m.playing_handicap or 0
        for hole, gross in holes.items():
            in_fb = hole in fb_holes_set
            # Pick the SO baseline + this player's index for this hole.
            if in_fb and hole in donor_hcp_by_hole:
                donor_hcp = donor_hcp_by_hole[hole]
                low = min(low_real, donor_hcp)
                hcp = donor_hcp if pid == phantom_pid else base_hcp
            elif in_fb and use_scratch_phantom:
                low = 0   # legacy: phantom scratch → real players play full HC
                hcp = base_hcp
            else:
                low = low_real
                hcp = base_hcp
            so = max(0, hcp - low)
            if game.net_percent != 100:
                so = int(round(so * game.net_percent / 100.0))
            si = m.tee.hole(hole).get('stroke_index', 18)
            strokes = 0
            if si <= so:
                strokes = 1 + (1 if si + 18 <= so else 0)
            out.setdefault(pid, {})[hole] = gross - strokes
    return out


def _so_baseline_for_match(
    match, team1_pids, team2_pids, members_by_pid, pair_indexes,
) -> int | None:
    """Return the playing_handicap baseline ('plays to 0' value) the
    scorer used for this match in SO mode.  Branches:
      • Per-pair SO reset (singles match without the foursome low):
        baseline = the lower of just those two players.
      • 2v1 fourball: baseline = 0 (the scratch phantom is the low),
        so every real player's SO badge reflects full-HC strokes.
      • Everything else: baseline = the lowest REAL player in the
        foursome.
    """
    if match.id in pair_indexes:
        pair = [members_by_pid.get(p) for p in team1_pids + team2_pids]
        hcps = [m.playing_handicap for m in pair
                if m is not None and m.playing_handicap is not None]
        return min(hcps) if hcps else None
    # 2v1 fourball phantom baseline:
    #   • net_par (non-donor) phantom is scratch → baseline 0 (real players
    #     carry full HC, matching the scratch dots).
    #   • cross-foursome DONOR phantom uses the per-hole donor low; its
    #     per-segment representative badge is the real foursome low, so fall
    #     through.  (Exact dots are per-hole in _strokes_by_hole_for_match;
    #     on a hole where the donor is below the real low the dots can exceed
    #     this badge by one.)
    if match.segment == 'fourball' and any(
        m.player.is_phantom for m in members_by_pid.values()
    ):
        phantom_m = next((m for m in members_by_pid.values()
                          if m.player.is_phantom), None)
        if (phantom_m is None
                or phantom_m.phantom_algorithm != CROSS_FOURSOME_ALGORITHM_ID):
            return 0
    low_pid = _foursome_low_pid(members_by_pid)
    if low_pid is None:
        return None
    return members_by_pid[low_pid].playing_handicap


def _foursome_low_pid(members_by_pid: dict) -> int | None:
    """Player ID of the lowest playing_handicap REAL player in the
    foursome.  Used to detect which singles match needs a per-pair
    SO reset (the one that doesn't include this player)."""
    best_pid = None
    best_hcp = None
    for pid, m in members_by_pid.items():
        if m.player.is_phantom:
            continue
        if m.playing_handicap is None:
            continue
        if best_hcp is None or m.playing_handicap < best_hcp:
            best_hcp = m.playing_handicap
            best_pid = pid
    return best_pid


def _singles_pair_so_index(
    pair_pids: list[int],
    gross_index: dict,
    members_by_pid: dict,
    start_hole: int,
    end_hole: int,
    net_percent: int,
) -> dict:
    """Build a {pid: {hole: net}} score index for *just these two
    players* under per-pair strokes-off: the lower-handicap of the
    two plays to 0; the higher gets `(high - low) × net_percent/100`
    strokes via plain WHS allocation (any hole in the singles range
    whose SI ≤ SO gets a stroke).  Holes the players haven't yet
    scored are absent — the scorer treats "missing" as "not yet
    playable" already."""
    if len(pair_pids) != 2:
        return {}
    m_a = members_by_pid.get(pair_pids[0])
    m_b = members_by_pid.get(pair_pids[1])
    if m_a is None or m_b is None:
        return {}
    if m_a.tee_id is None or m_b.tee_id is None:
        return {}

    low_hcp = min(m_a.playing_handicap or 0, m_b.playing_handicap or 0)
    pair_so = {
        m_a.player_id: max(0, (m_a.playing_handicap or 0) - low_hcp),
        m_b.player_id: max(0, (m_b.playing_handicap or 0) - low_hcp),
    }
    if net_percent != 100:
        pair_so = {pid: int(round(so * net_percent / 100.0))
                   for pid, so in pair_so.items()}

    out: dict = {}
    seg_range = range(start_hole, end_hole + 1)
    for pid in pair_pids:
        m = members_by_pid[pid]
        strokes_per_hole = _allocate_whs(pair_so[pid], seg_range, m.tee)
        for h in seg_range:
            gross = gross_index.get(pid, {}).get(h)
            if gross is None:
                continue
            out.setdefault(pid, {})[h] = gross - strokes_per_hole.get(h, 0)
    return out


def _resolve_first_tee(
    team_pids: list[int],
    requested: int | None,
    members_by_pid: dict,
    *,
    auto_default: bool = True,
) -> int | None:
    """Pick the alt-shot first-tee player for a foursomes team.
    Honours an explicit requested player when it's on the team.
    When *auto_default* is True (casual flow) falls back to the
    lower-handicap real player; when False (cup flow) returns None
    so the score-entry modal will fire on hole 7 and let the
    team pick at game time.  Single-player teams (2v1 solo side)
    always return None — no alternation."""
    real_pids = [p for p in team_pids
                 if (m := members_by_pid.get(p)) and not m.player.is_phantom]
    if len(real_pids) < 2:
        return None
    if requested is not None and requested in real_pids:
        return requested
    if not auto_default:
        return None
    return _sort_by_handicap(real_pids, members_by_pid)[0]


def _sort_by_handicap(player_ids: list[int], members_by_pid: dict) -> list[int]:
    """Return *player_ids* re-ordered by ascending playing_handicap
    (lowest first).  Players we can't find a membership for keep their
    original position at the end."""
    def key(pid):
        m = members_by_pid.get(pid)
        if m is None or m.playing_handicap is None:
            return (1, 0)  # unknowns sink to the bottom
        return (0, m.playing_handicap)
    return sorted(player_ids, key=key)


def reconfigure_triple_cup(
    foursome,
    team1_ids: list[int],
    team2_ids: list[int],
) -> None:
    """Tear down and rebuild a foursome's TripleCupGame to match the
    given team rosters (real players only).  Used by the tee-box
    operations — no-show removal, player move, foursome swap — when
    the roster of a foursome already running TC changes shape.

    Handles the phantom-membership lifecycle that setup_triple_cup
    itself does NOT (it expects the phantom row to already exist when
    it's needed):
      • new size 3 + no existing phantom → create one
      • new size != 3 + existing phantom → strip it (4-player & 2-player
        TC don't use a phantom partner)

    Preserves the existing handicap config (mode, net%, alt-shot
    allowances) — snapshotted before the old game is deleted.
    Idempotent at the foursome level: safe to call repeatedly,
    each call rebuilds the match plan from scratch.

    Callers wrap in transaction.atomic so a partial failure (e.g.
    invalid roster split) rolls back the whole change.
    """
    from tournament.models import FoursomeMembership
    from services.round_setup import _get_or_create_phantom

    new_size = len(team1_ids) + len(team2_ids)
    if new_size < 2:
        raise ValueError(
            f"reconfigure_triple_cup requires ≥2 real players "
            f"(got team1={len(team1_ids)}, team2={len(team2_ids)})"
        )

    # Snapshot the existing TC config so the rebuild keeps the user's
    # handicap settings.  No game yet?  Caller probably set
    # foursome.triple_cup_game to None; we accept that and use defaults.
    try:
        tc_game = foursome.triple_cup_game
    except Exception:
        tc_game = None
    if tc_game is not None:
        hcap_kwargs = {
            'handicap_mode'   : tc_game.handicap_mode,
            'net_percent'     : tc_game.net_percent,
            'alt_shot_low_pct': tc_game.alt_shot_low_pct,
            'alt_shot_high_pct': tc_game.alt_shot_high_pct,
        }
        tc_game.delete()
    else:
        hcap_kwargs = {}

    # Manage phantom membership for the new size — see docstring.
    existing_phantom_m = (
        foursome.memberships
        .filter(player__is_phantom=True)
        .first()
    )
    if new_size == 3 and existing_phantom_m is None:
        phantom_player = _get_or_create_phantom(foursome.round.account)
        real_m = (
            foursome.memberships
            .filter(player__is_phantom=False)
            .select_related('tee')
            .first()
        )
        FoursomeMembership.objects.create(
            foursome         = foursome,
            player           = phantom_player,
            tee              = real_m.tee if real_m else None,
            course_handicap  = 0,   # scratch — D1 contract
            playing_handicap = 0,
        )
        foursome.has_phantom = True
        foursome.save(update_fields=['has_phantom'])
    elif new_size != 3 and existing_phantom_m is not None:
        existing_phantom_m.delete()
        foursome.has_phantom = False
        foursome.save(update_fields=['has_phantom'])

    setup_triple_cup(
        foursome,
        team1_ids = team1_ids,
        team2_ids = team2_ids,
        **hcap_kwargs,
    )


def _ensure_phantom_for_2v1(foursome, team1_ids: list[int],
                            team2_ids: list[int]) -> int:
    """
    Verify the foursome has a phantom membership and that its donor
    rotation is configured for the solo's team.  Returns the phantom
    player ID.  Raises ValueError if the round isn't set up to
    support 2v1 (no phantom membership, or solo isn't on a cup team).
    """
    phantom_m = (
        foursome.memberships
        .filter(player__is_phantom=True)
        .select_related('player', 'tee')
        .first()
    )
    if phantom_m is None:
        raise ValueError(
            "2v1 Triple Cup requires a phantom membership in the foursome. "
            "Use the cup setup wizard to add the 3-player group — it "
            "auto-creates the phantom so cross-foursome donors can post "
            "fourball scores."
        )

    # If donor rotation isn't already configured (e.g. user is wiring up
    # Triple Cup manually after the wizard ran for a different game),
    # configure it now using the solo's TournamentTeam.
    if phantom_m.phantom_algorithm != CROSS_FOURSOME_ALGORITHM_ID:
        solo_team = _solo_tournament_team(foursome, team1_ids, team2_ids)
        if solo_team is None:
            raise ValueError(
                "Cannot configure phantom: the solo player isn't on a "
                "TournamentTeam in this Ryder Cup tournament."
            )
        ok = setup_cross_foursome_phantom(foursome, solo_team, foursome.round)
        if not ok:
            raise ValueError(
                "Cannot configure phantom: no eligible donor players "
                "found on the solo's team in other foursomes of this round."
            )
    else:
        # Already configured — but the algorithm's playing-handicap rule
        # may have changed since this phantom was first set up (D1: now
        # always 0 / scratch).  Re-sync the stored value so existing
        # rounds pick up the new scratch behavior without forcing the
        # user to wipe + re-create the foursome.  Idempotent: rotation
        # and donor names are NOT reshuffled.
        from scoring.phantom import get_algorithm
        algo = get_algorithm(phantom_m.phantom_algorithm)
        new_hcp = algo.compute_playing_handicap(
            phantom_m.phantom_config or {}, []
        )
        if phantom_m.playing_handicap != new_hcp:
            phantom_m.playing_handicap = new_hcp
            # course_handicap mirrors playing_handicap for scratch
            # phantoms — keeps the leaderboard "Index" column honest.
            phantom_m.course_handicap = new_hcp
            phantom_m.save(update_fields=[
                'playing_handicap', 'course_handicap',
            ])

    return phantom_m.player_id


def _tc_match_point_value(group_size: int, match_number: int) -> float:
    """Cup points awarded for a decided TC match.

    Every group_size contributes 4 points to the cup, but the split
    across matches depends on the format:
      • 4-player (2v2) → 4 matches × 1 pt each (Fourball, Foursomes,
        Singles 1, Singles 2).
      • 3-player (2v1) → 4 matches × 1 pt each (same shape with
        phantom-partnered fourball, alt-shot, two singles).
      • 2-player (1v1) → Nassau: F9 (m1) = 1, B9 (m2) = 1, Overall
        (m3) = 2.  Overall is the marquee bet, weighted 2×.

    Halves split the match's point value evenly between the two sides.
    """
    if group_size == 2:
        return 2.0 if match_number == 3 else 1.0
    return 1.0


def _build_match_plan(
    team1_ids: list[int],
    team2_ids: list[int],
    *,
    phantom_pid: int | None = None,
) -> list[dict]:
    """
    Decide which matches to create for the given player IDs.

    Returns a list of dicts shaped like:
        {'match_number': 1, 'segment': 'fourball', 'label': 'Fourball',
         'start_hole': 1, 'end_hole': 6,
         'team1_ids': [...], 'team2_ids': [...]}

    In 2v1, *phantom_pid* (when supplied) is appended to the solo's
    side for the fourball match only — the phantom acts as the solo's
    best-ball partner and pulls its gross from cross-foursome donors.

    Raises ValueError on player counts the format doesn't support.
    """
    n1, n2 = len(team1_ids), len(team2_ids)
    total  = n1 + n2

    if total < 2 or total > 4 or n1 < 1 or n2 < 1:
        raise ValueError(
            f"Triple Cup needs 2–4 real players split across two sides "
            f"(got team1={n1}, team2={n2})."
        )

    plan = []

    # ── 2v2 (canonical): 1 fourball + 1 foursomes + 2 singles ─────────────
    if n1 == 2 and n2 == 2:
        plan.append({
            'match_number': 1, 'segment': 'fourball', 'label': 'Fourball',
            'start_hole': 1, 'end_hole': 6,
            'team1_ids': team1_ids, 'team2_ids': team2_ids,
        })
        plan.append({
            'match_number': 2, 'segment': 'foursomes', 'label': 'Foursomes',
            'start_hole': 7, 'end_hole': 12,
            'team1_ids': team1_ids, 'team2_ids': team2_ids,
        })
        # Singles: pair top-of-list with top-of-list, bottom with bottom.
        # The caller controls the order, so they can match by handicap rank
        # or by personal preference at setup time.
        plan.append({
            'match_number': 3, 'segment': 'singles', 'label': 'Singles 1',
            'start_hole': 13, 'end_hole': 18,
            'team1_ids': [team1_ids[0]], 'team2_ids': [team2_ids[0]],
        })
        plan.append({
            'match_number': 4, 'segment': 'singles', 'label': 'Singles 2',
            'start_hole': 13, 'end_hole': 18,
            'team1_ids': [team1_ids[1]], 'team2_ids': [team2_ids[1]],
        })
        return plan

    # ── 2v1: solo + phantom partner in fourball; solo carries rest ──
    if {n1, n2} == {1, 2}:
        # Identify pair and solo so we can attach the phantom to the
        # solo's side for fourball only.
        if n1 == 2:
            pair, solo = team1_ids, team2_ids
            solo_side  = 'team2'
        else:
            pair, solo = team2_ids, team1_ids
            solo_side  = 'team1'

        # Fourball: phantom partners with the solo (cross-foursome donor
        # scores propagate into HoleScore for the phantom player).
        solo_with_phantom = list(solo) + (
            [phantom_pid] if phantom_pid is not None else []
        )
        if solo_side == 'team1':
            fb_t1, fb_t2 = solo_with_phantom, list(team2_ids)
        else:
            fb_t1, fb_t2 = list(team1_ids), solo_with_phantom

        plan.append({
            'match_number': 1, 'segment': 'fourball', 'label': 'Fourball',
            'start_hole': 1, 'end_hole': 6,
            'team1_ids': fb_t1, 'team2_ids': fb_t2,
        })
        # Foursomes: solo plays alone (no phantom partner); pair alternates.
        plan.append({
            'match_number': 2, 'segment': 'foursomes', 'label': 'Foursomes',
            'start_hole': 7, 'end_hole': 12,
            'team1_ids': team1_ids, 'team2_ids': team2_ids,
        })
        # Singles: solo plays both opponents simultaneously (Phase D will
        # introduce a Shadow so each match has its own 1v1 pairing).
        if n1 == 2:
            singles_m3 = {'team1_ids': [pair[0]], 'team2_ids': solo}
            singles_m4 = {'team1_ids': [pair[1]], 'team2_ids': solo}
        else:
            singles_m3 = {'team1_ids': solo, 'team2_ids': [pair[0]]}
            singles_m4 = {'team1_ids': solo, 'team2_ids': [pair[1]]}
        plan.append({
            'match_number': 3, 'segment': 'singles', 'label': 'Singles 1',
            'start_hole': 13, 'end_hole': 18, **singles_m3,
        })
        plan.append({
            'match_number': 4, 'segment': 'singles', 'label': 'Singles 2',
            'start_hole': 13, 'end_hole': 18, **singles_m4,
        })
        return plan

    # ── 1v1 (2-player TC): single 18-hole Nassau, F9 / B9 / Overall ──
    # The two players don't have enough roster for a real 3-segment TC
    # (alt-shot needs 2 per side; fourball best-ball collapses to two
    # singles), so we play an 18-hole Nassau with three sub-matches:
    #   F9 (1-9, 1 pt) + B9 (10-18, 1 pt) + Overall (1-18, 2 pts)
    # = 4 points total, same cup contribution as a 4-player TC group.
    # All three are 1v1 match-play; the Overall match overlaps F9+B9
    # but tracks its own holes_up state independently.
    if n1 == 1 and n2 == 1:
        plan.append({
            'match_number': 1, 'segment': 'singles', 'label': 'Front 9',
            'start_hole': 1, 'end_hole': 9,
            'team1_ids': team1_ids, 'team2_ids': team2_ids,
        })
        plan.append({
            'match_number': 2, 'segment': 'singles', 'label': 'Back 9',
            'start_hole': 10, 'end_hole': 18,
            'team1_ids': team1_ids, 'team2_ids': team2_ids,
        })
        plan.append({
            'match_number': 3, 'segment': 'singles', 'label': 'Overall',
            'start_hole': 1, 'end_hole': 18,
            'team1_ids': team1_ids, 'team2_ids': team2_ids,
        })
        return plan

    raise ValueError(
        f"Unsupported Triple Cup roster shape: team1={n1}, team2={n2}. "
        f"Supported: 2v2, 2v1, 1v1."
    )


@transaction.atomic
def setup_triple_cup(
    foursome,
    team1_ids: list[int],
    team2_ids: list[int],
    *,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    alt_shot_low_pct: int = 50,
    alt_shot_high_pct: int = 50,
    foursomes_team1_first_tee: int | None = None,
    foursomes_team2_first_tee: int | None = None,
) -> TripleCupGame:
    """
    Create (or replace) a TripleCupGame and its matches/teams for a
    foursome.  Idempotent — calling again wipes prior matches/results.

    team1_ids / team2_ids are the real players on each side.  Phantoms
    in the foursome's membership are ignored; in 2v1 cup rounds the
    solo side's fourball uses cross-foursome donor scores (handled by
    Phase C / scoring.phantom).

    Casual 2v1 is rejected — there are no cross-team donors to draw
    from in a single-foursome round, and the synthetic-score fallback
    we used in v1 produced an inconsistent experience.  Run 2v1
    Triple Cup inside a cup round, or stick to 2v2 / 1v1 for casual.
    """
    n_total = len(team1_ids) + len(team2_ids)
    is_2v1  = n_total == 3
    is_cup  = _is_cup_round(foursome.round)
    if is_2v1 and not is_cup:
        raise ValueError(
            "2v1 Triple Cup is only supported inside a Ryder Cup round "
            "(needs cross-foursome teammates to donate phantom scores). "
            "Use 2v2 or 1v1 for casual rounds."
        )

    TripleCupGame.objects.filter(foursome=foursome).delete()

    # In 2v1 cup mode the foursome carries a phantom membership (added
    # by round-setup) who acts as the solo's fourball partner.  Make
    # sure its donor rotation is configured before we wire it into the
    # fourball match — the cup-setup wizard does this for Nassau but
    # may not have run for Triple Cup yet.
    phantom_pid = None
    if is_2v1:
        phantom_pid = _ensure_phantom_for_2v1(foursome, team1_ids, team2_ids)

    members_by_pid = _membership_by_pid(foursome)
    if is_2v1:
        # 2v1: the solo plays each pair member, so there's no low/high pairing
        # to preserve — order each side by the foursome's ON-SCREEN order
        # (membership order) so Singles 1/2, and the solo's twin SO badges,
        # line up top→bottom with the score-entry rows.
        order = [m.player_id for m in foursome.memberships.all()]
        rank = {pid: i for i, pid in enumerate(order)}
        keyf = lambda pid: rank.get(pid, len(order))   # noqa: E731
        sorted_t1 = sorted(team1_ids, key=keyf)
        sorted_t2 = sorted(team2_ids, key=keyf)
    else:
        # 2v2 / 1v1: sort by playing handicap (low first) so the singles
        # pairings go low-of-Red vs low-of-Blue and high vs high — the
        # standard cup match-up, regardless of how the rows were dragged.
        sorted_t1 = _sort_by_handicap(team1_ids, members_by_pid)
        sorted_t2 = _sort_by_handicap(team2_ids, members_by_pid)

    plan = _build_match_plan(sorted_t1, sorted_t2, phantom_pid=phantom_pid)

    game = TripleCupGame.objects.create(
        foursome           = foursome,
        status             = MatchStatus.PENDING,
        handicap_mode      = handicap_mode,
        net_percent        = max(0, min(200, int(net_percent))),
        alt_shot_low_pct   = max(0, min(100, int(alt_shot_low_pct))),
        alt_shot_high_pct  = max(0, min(100, int(alt_shot_high_pct))),
        group_size         = len(team1_ids) + len(team2_ids),
    )

    for entry in plan:
        m = TripleCupMatch.objects.create(
            game         = game,
            match_number = entry['match_number'],
            segment      = entry['segment'],
            label        = entry['label'],
            start_hole   = entry['start_hole'],
            end_hole     = entry['end_hole'],
            status       = MatchStatus.PENDING,
        )
        t1 = TripleCupTeam.objects.create(match=m, team_number=1)
        t1.players.set(entry['team1_ids'])
        t2 = TripleCupTeam.objects.create(match=m, team_number=2)
        t2.players.set(entry['team2_ids'])

        # Foursomes: pick (or accept) which player on each team tees
        # off first.  Casual rounds auto-default to the lower-
        # handicap real player on the team — the casual wizard picks
        # the team at setup time, so the auto-default keeps the flow
        # zero-click.  CUP rounds intentionally leave this null when
        # the admin didn't supply one — by convention the team
        # decides who tees off when they actually reach hole 7, and
        # the score-entry modal fires when first_tee is still null.
        if m.segment == 'foursomes':
            auto_default = not is_cup
            m.team1_first_tee_player_id = _resolve_first_tee(
                entry['team1_ids'], foursomes_team1_first_tee, members_by_pid,
                auto_default=auto_default,
            )
            m.team2_first_tee_player_id = _resolve_first_tee(
                entry['team2_ids'], foursomes_team2_first_tee, members_by_pid,
                auto_default=auto_default,
            )
            m.save(update_fields=[
                'team1_first_tee_player', 'team2_first_tee_player',
            ])

    return game


# ---------------------------------------------------------------------------
# Scoring helpers
# ---------------------------------------------------------------------------

def _membership_by_pid(foursome) -> dict:
    return {
        m.player_id: m
        for m in foursome.memberships.select_related('player', 'tee').all()
    }


def _par_by_hole(foursome) -> dict:
    """Par per hole for the first membership that has a tee — Triple
    Cup assumes every player in the foursome shares a tee/par layout,
    which matches every other game in this codebase."""
    for m in foursome.memberships.select_related('tee').all():
        if m.tee_id is None:
            continue
        return {h['number']: h['par'] for h in m.tee.holes}
    return {}


def _si_by_hole(foursome) -> dict:
    """Stroke index per hole from the first membership's tee.  Used by
    the leaderboard detail grid so users can verify which holes
    a player gets strokes on."""
    for m in foursome.memberships.select_related('tee').all():
        if m.tee_id is None:
            continue
        return {h['number']: h.get('stroke_index', 18) for h in m.tee.holes}
    return {}


def _gross_index(foursome, *, include_phantom: bool = False) -> dict:
    """Raw gross scores: {player_id: {hole: gross}}.  Phantoms are
    excluded by default; in 2v1 fourball pass include_phantom=True so
    the donor-supplied phantom gross is available to alt-shot scoring
    (the foursomes segment never uses the phantom, but the index is
    shared by all matches)."""
    qs = HoleScore.objects.filter(foursome=foursome)
    if not include_phantom:
        qs = qs.filter(player__is_phantom=False)
    rows = qs.exclude(gross_score=None).values(
        'player_id', 'hole_number', 'gross_score'
    )
    out: dict = {}
    for r in rows:
        out.setdefault(r['player_id'], {})[r['hole_number']] = r['gross_score']
    return out


def _alt_shot_team_combined(
    game: TripleCupGame,
    team_player_ids: list[int],
    members_by_pid: dict,
) -> tuple[int, object | None]:
    """Combined alt-shot handicap for a team (course-handicap units), with
    net_percent applied and a SINGLE round at the end (0.5 → up).

    Pair side weights each player's UNROUNDED course handicap
    (index × slope/113 + course_rating − par) by alt_shot_low/high_pct — so the
    result isn't stuck on the .5 you land on half the time when you average two
    already-rounded integer course handicaps.  Solo side uses that player's own
    course handicap.  net_percent (the SO allowance) comes off the combined
    value in BOTH cases.
    """
    def _raw_ch(m) -> float:
        t = m.tee
        idx = float(m.player.effective_handicap_index() or 0)
        return (idx * float(t.slope) / 113.0
                + float(t.course_rating) - float(t.par))

    members = [m for m in (members_by_pid.get(p) for p in team_player_ids)
               if m is not None and m.tee_id is not None]
    if not members:
        return 0, None
    tee = members[0].tee

    if len(members) == 1:
        # Solo — net% off their own course handicap.
        combined = (members[0].playing_handicap or 0) * game.net_percent / 100.0
    else:
        # Pair — weight the unrounded course handicaps, then net%.
        raws = sorted(_raw_ch(m) for m in members)
        weighted = (raws[0] * game.alt_shot_low_pct
                    + raws[-1] * game.alt_shot_high_pct) / 100.0
        combined = weighted * game.net_percent / 100.0
    return math.floor(combined + 0.5), tee   # round half UP


def _allocate_whs(strokes: int, hole_range, tee) -> dict[int, int]:
    """WHS course-wide allocation: one stroke per hole whose SI ≤
    *strokes*, with an extra cycle for strokes > 18.

    Used for BOTH net mode (full effective handicap) and SO mode
    (player's SO differential against the relevant baseline).  In
    every case the rule is "any hole with SI ≤ N gets a stroke" —
    Triple Cup deliberately skips the Sixes per-segment spreading
    so a player with SO=9 picks up a stroke on hole 4 (SI 4)
    regardless of whether that hole happens to be one of the
    segment's top three hardest."""
    out = {h: 0 for h in hole_range}
    if strokes <= 0 or tee is None:
        return out
    for h in hole_range:
        si = tee.hole(h).get('stroke_index', 18)
        if si <= strokes:
            out[h] = 1 + (1 if si + 18 <= strokes else 0)
    return out


def _fourball_donor_so_by_hole(
    match, t1_pids, t2_pids, members_by_pid, game,
) -> dict[int, dict[int, int]]:
    """{player_id: {hole: SO}} for a 2v1 cross-foursome fourball — the per-hole
    strokes-off VALUE (player index − the hole's donor-inclusive low), so the
    "-N" badge matches the per-hole donor dots.  Empty when not applicable
    (non-fourball, no cross-foursome phantom, or non-SO mode)."""
    if (match.segment != 'fourball'
            or game.handicap_mode != HandicapMode.STROKES_OFF):
        return {}
    phantom_m = next((m for m in members_by_pid.values()
                      if m.player.is_phantom), None)
    if (phantom_m is None
            or phantom_m.phantom_algorithm != CROSS_FOURSOME_ALGORITHM_ID):
        return {}
    from scoring.phantom import get_algorithm
    algo = get_algorithm(phantom_m.phantom_algorithm)
    cfg  = phantom_m.phantom_config or {}
    real_hcps = [m.playing_handicap for m in members_by_pid.values()
                 if m.playing_handicap is not None and not m.player.is_phantom]
    low_real = min(real_hcps) if real_hcps else 0
    out: dict = {}
    for pid in list(t1_pids) + list(t2_pids):
        m = members_by_pid.get(pid)
        if m is None:
            continue
        is_ph = m.player.is_phantom
        for h in range(match.start_hole, match.end_hole + 1):
            donor_hcp = algo.donor_handicap(h, cfg)
            if donor_hcp is None:
                low, hcp = low_real, (m.playing_handicap or 0)
            else:
                low = min(low_real, donor_hcp)
                hcp = donor_hcp if is_ph else (m.playing_handicap or 0)
            so = max(0, hcp - low)
            if game.net_percent != 100:
                so = int(round(so * game.net_percent / 100.0))
            out.setdefault(pid, {})[h] = so
    return out


def _expected_strokes_per_match(
    match,
    matches,
    t1_pids: list[int],
    t2_pids: list[int],
    game,
    members_by_pid: dict,
    foursome_low_pid: int | None,
) -> dict[int, dict[int, int]]:
    """{player_id: {hole: strokes}} of expected handicap strokes per
    hole in this match's range.  Allocation is always plain WHS
    ("any hole with SI ≤ N gets a stroke") against a baseline that
    depends on the segment + handicap mode:

      * Foursomes → team alt-shot strokes (team-vs-team SO in SO mode,
        each-team-combined in NET mode); same dict on BOTH partners
        so whoever tees off this hole shows the team's dots.
      * Fourball + Singles, NET mode → each player's full playing
        handicap × net% (the standard "hcp 12 gets strokes on the
        12 hardest holes" rule).
      * Fourball + Singles, SO mode → each player's SO differential
        × net%.  Baseline is the foursome low for most matches; for
        the singles match that doesn't contain the foursome low
        we reset to per-pair (lower of the two plays to scratch).

    Same numbers feed:
      • leaderboard team / player stroke dots
      • score-entry top-card stroke dots
      • derived `strokes` in scored-hole rows (so the value the user
        sees on a scored hole matches what they saw before scoring).
    """
    seg_range = range(match.start_hole, match.end_hole + 1)
    result: dict = {pid: {h: 0 for h in seg_range}
                    for pid in t1_pids + t2_pids}

    if match.segment == 'foursomes':
        t1_strokes, t2_strokes = _foursomes_team_strokes(
            game, t1_pids, t2_pids, members_by_pid, seg_range,
        )
        for pid in t1_pids:
            result[pid] = dict(t1_strokes)
        for pid in t2_pids:
            result[pid] = dict(t2_strokes)
        return result

    if game.handicap_mode == HandicapMode.GROSS:
        return result

    pair_pids = list(t1_pids) + list(t2_pids)

    # 2v1 fourball with a cross-foursome donor phantom — per-hole donor
    # strokes-off (mirrors _whs_so_net_index).  Each hole is scored as a real
    # 4-some incl. that hole's donor, so the low (and everyone's dots)
    # recompute hole-by-hole and the phantom's dots use the donor's index.
    # Returns directly because the baseline isn't constant across the segment.
    if (match.segment == 'fourball'
            and game.handicap_mode == HandicapMode.STROKES_OFF):
        phantom_m = next((m for m in members_by_pid.values()
                          if m.player.is_phantom), None)
        if (phantom_m is not None
                and phantom_m.phantom_algorithm == CROSS_FOURSOME_ALGORITHM_ID):
            from scoring.phantom import get_algorithm
            algo = get_algorithm(phantom_m.phantom_algorithm)
            cfg  = phantom_m.phantom_config or {}
            real_hcps = [m.playing_handicap for m in members_by_pid.values()
                         if m.playing_handicap is not None
                         and not m.player.is_phantom]
            low_real = min(real_hcps) if real_hcps else 0
            for pid in pair_pids:
                m = members_by_pid.get(pid)
                if m is None or m.tee_id is None:
                    continue
                is_ph = m.player.is_phantom
                for h in seg_range:
                    donor_hcp = algo.donor_handicap(h, cfg)
                    if donor_hcp is None:
                        low, hcp = low_real, (m.playing_handicap or 0)
                    else:
                        low = min(low_real, donor_hcp)
                        hcp = donor_hcp if is_ph else (m.playing_handicap or 0)
                    so = max(0, hcp - low)
                    if game.net_percent != 100:
                        so = int(round(so * game.net_percent / 100.0))
                    si = m.tee.hole(h).get('stroke_index', 18)
                    result[pid][h] = (
                        1 + (1 if si + 18 <= so else 0) if si <= so else 0
                    )
            return result

    # Pick the per-player baseline.  SO mode uses the foursome low
    # for most matches; a singles match without the foursome low
    # resets to its own per-pair low.  NET mode uses 0 (i.e. each
    # player carries their full effective handicap).
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        if (match.segment == 'singles'
                and foursome_low_pid is not None
                and foursome_low_pid not in pair_pids):
            hcps = [members_by_pid[p].playing_handicap or 0
                    for p in pair_pids if p in members_by_pid]
            baseline = min(hcps) if hcps else 0
        elif match.segment == 'fourball' and any(
            m.player.is_phantom for m in members_by_pid.values()
        ):
            # 2v1 fourball with a NON-donor phantom (net_par synthesis) —
            # the scratch phantom is the low, so real players carry full HC.
            baseline = 0
        else:
            real_hcps = [m.playing_handicap
                         for m in members_by_pid.values()
                         if m.playing_handicap is not None
                         and not m.player.is_phantom]
            baseline = min(real_hcps) if real_hcps else 0
    else:
        baseline = 0  # NET mode — use full effective handicap

    for pid in pair_pids:
        m = members_by_pid.get(pid)
        if m is None or m.tee_id is None:
            continue
        eff = max(0, (m.playing_handicap or 0) - baseline)
        if game.net_percent != 100:
            eff = int(round(eff * game.net_percent / 100.0))
        result[pid] = _allocate_whs(eff, seg_range, m.tee)
    return result


def _foursomes_team_strokes(
    game: TripleCupGame,
    t1_pids: list[int],
    t2_pids: list[int],
    members_by_pid: dict,
    hole_range,
) -> tuple[dict[int, int], dict[int, int]]:
    """Return (t1_strokes_by_hole, t2_strokes_by_hole) for an
    alt-shot foursomes match.  In NET mode each team gets its own
    combined alt-shot handicap.  In STROKES-OFF mode the team with
    the LOWER combined handicap plays to scratch and the other team
    receives the differential — so the dots on the entry screen and
    leaderboard read as a head-to-head between two synthetic
    "team" players whose handicaps are their alt-shot allowances."""
    c1, tee1 = _alt_shot_team_combined(game, t1_pids, members_by_pid)
    c2, tee2 = _alt_shot_team_combined(game, t2_pids, members_by_pid)
    tee = tee1 or tee2
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        # Team-vs-team SO: low team plays scratch, high team gets
        # the differential.  Then WHS-allocate that differential
        # across all 18 holes by SI — we only render what lands
        # inside the foursomes range (7–12).
        if c1 <= c2:
            t1_eff, t2_eff = 0, c2 - c1
        else:
            t1_eff, t2_eff = c1 - c2, 0
    else:
        # NET mode: each team carries its full combined handicap.
        t1_eff, t2_eff = c1, c2
    return (
        _allocate_whs(t1_eff, hole_range, tee),
        _allocate_whs(t2_eff, hole_range, tee),
    )


def _score_fourball_or_singles(
    match: TripleCupMatch,
    team1_pids: list[int],
    team2_pids: list[int],
    net_index: dict,
) -> tuple[list[TripleCupHoleResult], int | None]:
    """Best-of-team-nets per hole.  In 2v1 fourball the phantom is
    one of the team's player_ids and its net comes from the same
    score index as the real players (populated by
    propagate_phantom_score from cross-foursome donor scores)."""
    holes_up    = 0
    finished_on = None
    results     = []

    for h in range(match.start_hole, match.end_hole + 1):
        t1_nets = [net_index[p][h] for p in team1_pids
                   if p in net_index and h in net_index[p]]
        t2_nets = [net_index[p][h] for p in team2_pids
                   if p in net_index and h in net_index[p]]

        if not t1_nets or not t2_nets:
            break

        t1_net = min(t1_nets)
        t2_net = min(t2_nets)

        if t1_net < t2_net:
            holes_up += 1
            winner = 1
        elif t2_net < t1_net:
            holes_up -= 1
            winner = 2
        else:
            winner = None

        remaining = match.end_hole - h
        if abs(holes_up) > remaining:
            finished_on = h

        results.append(TripleCupHoleResult(
            match               = match,
            hole_number         = h,
            team1_net           = t1_net,
            team2_net           = t2_net,
            winning_team_number = winner,
            holes_up_after      = holes_up,
        ))
        if finished_on:
            break

    return results, finished_on


def _score_foursomes(
    match: TripleCupMatch,
    team1_pids: list[int],
    team2_pids: list[int],
    gross_index: dict,
    game: TripleCupGame,
    members_by_pid: dict,
) -> tuple[list[TripleCupHoleResult], int | None]:
    """
    Alt-shot scoring: one ball per team per hole.  Team gross = the
    lowest gross any team-member recorded that hole (in true alt-shot
    only one player records, so this picks that value; if both filled
    it in we take the lower — pragmatic for casual play).  Team net =
    team_gross − team_strokes_for_hole, where the team's combined
    handicap is allocated by stroke index across this 6-hole window.
    """
    seg_range = range(match.start_hole, match.end_hole + 1)
    t1_strokes, t2_strokes = _foursomes_team_strokes(
        game, team1_pids, team2_pids, members_by_pid, seg_range,
    )

    holes_up    = 0
    finished_on = None
    results     = []

    for h in seg_range:
        t1_grosses = [gross_index[p][h] for p in team1_pids
                      if p in gross_index and h in gross_index[p]]
        t2_grosses = [gross_index[p][h] for p in team2_pids
                      if p in gross_index and h in gross_index[p]]
        if not t1_grosses or not t2_grosses:
            break

        t1_net = min(t1_grosses) - t1_strokes.get(h, 0)
        t2_net = min(t2_grosses) - t2_strokes.get(h, 0)

        if t1_net < t2_net:
            holes_up += 1
            winner = 1
        elif t2_net < t1_net:
            holes_up -= 1
            winner = 2
        else:
            winner = None

        remaining = match.end_hole - h
        if abs(holes_up) > remaining:
            finished_on = h

        results.append(TripleCupHoleResult(
            match               = match,
            hole_number         = h,
            team1_net           = t1_net,
            team2_net           = t2_net,
            winning_team_number = winner,
            holes_up_after      = holes_up,
        ))
        if finished_on:
            break

    return results, finished_on


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_triple_cup(foursome) -> list[TripleCupHoleResult]:
    """
    Score all Triple Cup matches for this foursome.  Idempotent —
    existing hole-result rows are deleted and rebuilt on every call.
    Returns the flat list of all results saved this call (mainly for
    test introspection).
    """
    try:
        game = TripleCupGame.objects.get(foursome=foursome)
    except TripleCupGame.DoesNotExist:
        return []

    matches = list(
        game.matches.prefetch_related('teams__players').order_by('match_number')
    )
    if not matches:
        return []

    members_by_pid = _membership_by_pid(foursome)

    # Indexes are shared between scoring (here) and the summary view.
    gross_index, net_index, pair_indexes = _build_score_indexes(
        game, foursome, matches, members_by_pid,
    )

    all_results: list[TripleCupHoleResult] = []
    any_in_progress = False
    any_started     = False
    all_done        = True

    for match in matches:
        t1 = next((t for t in match.teams.all() if t.team_number == 1), None)
        t2 = next((t for t in match.teams.all() if t.team_number == 2), None)
        if t1 is None or t2 is None:
            match.status = MatchStatus.PENDING
            match.save(update_fields=['status'])
            all_done = False
            continue

        team1_pids = list(t1.players.values_list('id', flat=True))
        team2_pids = list(t2.players.values_list('id', flat=True))

        TripleCupHoleResult.objects.filter(match=match).delete()

        if match.segment == 'foursomes':
            results, finished_on = _score_foursomes(
                match, team1_pids, team2_pids, gross_index, game, members_by_pid,
            )
        else:
            # SO-reset singles matches are handled via pair_indexes.
            index_for_match = pair_indexes.get(match.id, net_index)
            results, finished_on = _score_fourball_or_singles(
                match, team1_pids, team2_pids, index_for_match,
            )

        TripleCupHoleResult.objects.bulk_create(results)
        all_results.extend(results)

        holes_played = len(results)
        holes_in_seg = match.end_hole - match.start_hole + 1
        holes_up     = results[-1].holes_up_after if results else 0

        if holes_played == 0:
            match.status               = MatchStatus.PENDING
            match.result               = None
            match.finished_on_hole     = None
            match.holes_up_after_final = 0
            t1.is_winner = False
            t2.is_winner = False
            all_done = False
        elif holes_played < holes_in_seg and finished_on is None:
            match.status               = MatchStatus.IN_PROGRESS
            match.result               = None
            match.finished_on_hole     = None
            match.holes_up_after_final = holes_up
            t1.is_winner = False
            t2.is_winner = False
            any_in_progress = True
            any_started     = True
            all_done        = False
        else:
            # Decided: either ran the full segment or clinched early.
            match.holes_up_after_final = holes_up
            match.finished_on_hole     = finished_on
            if holes_up > 0:
                match.status = MatchStatus.COMPLETE
                match.result = 'team1'
                t1.is_winner, t2.is_winner = True, False
            elif holes_up < 0:
                match.status = MatchStatus.COMPLETE
                match.result = 'team2'
                t1.is_winner, t2.is_winner = False, True
            else:
                match.status = MatchStatus.HALVED
                match.result = 'halved'
                t1.is_winner, t2.is_winner = False, False
            any_started = True

        match.save(update_fields=[
            'status', 'result', 'finished_on_hole', 'holes_up_after_final',
        ])
        t1.save(update_fields=['is_winner'])
        t2.save(update_fields=['is_winner'])

    # Roll game status up from its children.
    if not any_started:
        game.status = MatchStatus.PENDING
    elif all_done:
        game.status = MatchStatus.COMPLETE
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])

    return all_results


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def _player_names(pids: list[int], members_by_pid: dict) -> list[str]:
    out = []
    for pid in pids:
        m = members_by_pid.get(pid)
        if m is None:
            continue
        out.append(m.player.name)
    return out


def _player_shorts(pids: list[int], members_by_pid: dict) -> list[str]:
    out = []
    for pid in pids:
        m = members_by_pid.get(pid)
        if m is None:
            continue
        out.append(m.player.short_name or m.player.name[:5])
    return out


def _build_score_indexes(game, foursome, matches, members_by_pid):
    """Shared between calculate_triple_cup and triple_cup_summary.
    Returns (gross_index, net_index, pair_indexes_by_match_id).

    pair_indexes_by_match_id is non-empty only in SO mode: it carries
    the per-pair SO override score index for the singles match(es)
    that don't include the foursome's lowest player.
    """
    include_phantom = game.group_size == 3
    gross_index = _gross_index(foursome, include_phantom=include_phantom)

    # Fourball segment holes — used in 2v1 (group_size == 3) so the SO
    # baseline collapses to scratch on those holes (phantom is the low).
    # Empty for 4-player groups; segment-scoped low handling stays off.
    fourball_holes: set = set()
    if include_phantom:
        for m in matches:
            if m.segment == 'fourball':
                fourball_holes.update(range(m.start_hole, m.end_hole + 1))

    # SO mode: build our own WHS-based net index (foursome low plays
    # to 0, everyone else gets net = gross − strokes where strokes is
    # the WHS allocation of their SO).  We DON'T delegate to
    # build_score_index because that path either falls back to net@100
    # (no segments) or does Sixes-style per-segment spreading (with
    # segments) — neither matches the WHS-with-SO rule the user wants.
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        net_index = _whs_so_net_index(
            foursome, game, members_by_pid, gross_index,
            include_phantom=include_phantom,
            fourball_holes=fourball_holes,
        )
    else:
        net_index = build_score_index(
            foursome,
            handicap_mode   = game.handicap_mode,
            net_percent     = game.net_percent,
            include_phantom = include_phantom,
        )

    pair_indexes: dict = {}
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        foursome_low_pid = _foursome_low_pid(members_by_pid)
        if foursome_low_pid is not None:
            for match in matches:
                if match.segment != 'singles':
                    continue
                t1 = next((t for t in match.teams.all()
                           if t.team_number == 1), None)
                t2 = next((t for t in match.teams.all()
                           if t.team_number == 2), None)
                if not t1 or not t2:
                    continue
                t1p = list(t1.players.values_list('id', flat=True))
                t2p = list(t2.players.values_list('id', flat=True))
                if foursome_low_pid in t1p + t2p:
                    continue
                pair_indexes[match.id] = _singles_pair_so_index(
                    t1p + t2p, gross_index, members_by_pid,
                    match.start_hole, match.end_hole, game.net_percent,
                )
    return gross_index, net_index, pair_indexes


def triple_cup_summary(foursome) -> dict | None:
    """
    Return the JSON-friendly summary the mobile client consumes.  None
    when no Triple Cup game has been set up for this foursome.

    Shape
    -----
    {
        'status'              : 'pending'|'in_progress'|'complete',
        'group_size'          : 2|3|4,
        'handicap'            : {'mode': str, 'net_percent': int,
                                 'alt_shot_low_pct': int,
                                 'alt_shot_high_pct': int,
                                 'phantom_score_mode': str},
        'matches' : [
            {
                'match_number'   : 1..4,
                'segment'        : 'fourball'|'foursomes'|'singles',
                'label'          : 'Fourball'|'Foursomes'|'Singles 1'|...,
                'start_hole'     : int,
                'end_hole'       : int,
                'status'         : str,
                'result'         : 'team1'|'team2'|'halved'|None,
                'finished_on_hole': int|None,
                'holes_up_final' : int,   # signed, +ve = team1
                'winner_label'   : 'Team 1'|'Team 2'|'Halved'|'—',
                'team1'          : {'players': [names], 'shorts': [shorts]},
                'team2'          : {'players': [names], 'shorts': [shorts]},
                'holes'          : [{'hole': n, 't1_net': x, 't2_net': y,
                                     'winner': 'T1'|'T2'|'Halved',
                                     'margin': n}],
            }, ...
        ],
        'overall' : {
            'team1_wins'   : int,
            'team2_wins'   : int,
            'halves'       : int,
            'team1_points' : float,   # 1 per win, 0.5 per halve
            'team2_points' : float,
            'points_available': int,  # equals len(matches)
        },
        'money' : {
            'bet_unit'  : float,
            'by_player' : [{'name': str, 'amount': float}, ...],
        },
    }
    """
    try:
        game = TripleCupGame.objects.get(foursome=foursome)
    except TripleCupGame.DoesNotExist:
        return None

    members_by_pid = _membership_by_pid(foursome)
    par_by_hole    = _par_by_hole(foursome)
    si_by_hole     = _si_by_hole(foursome)

    matches = list(
        game.matches
        .prefetch_related('teams__players', 'hole_results')
        .order_by('match_number')
    )

    # Rebuild the same indexes the calculator uses so per-player
    # strokes/net reflect the game's actual handicap mode (NET %, SO
    # foursome-wide, or SO per-pair singles override) — not the raw
    # HoleScore.handicap_strokes which always carries full-net-at-100.
    gross_index, net_index, pair_indexes = _build_score_indexes(
        game, foursome, matches, members_by_pid,
    )
    foursome_low_pid = (
        _foursome_low_pid(members_by_pid)
        if game.handicap_mode == HandicapMode.STROKES_OFF else None
    )

    bet_unit       = float(foursome.round.bet_unit)
    money_totals: dict = {}
    t1_wins = t2_wins = halves = 0
    t1_points = t2_points = 0.0
    matches_out = []

    # The cup-level team rosters used for money settlement come from
    # match 1 (fourball in 2v2/2v1, first segment in 1v1).  In 2v1
    # this includes the phantom on the solo's side — the phantom is
    # filtered out before money is moved.
    cup_red_pids: list[int]  = []
    cup_blue_pids: list[int] = []
    if matches:
        first = matches[0]
        t1_first = next((t for t in first.teams.all() if t.team_number == 1), None)
        t2_first = next((t for t in first.teams.all() if t.team_number == 2), None)
        if t1_first:
            cup_red_pids  = list(t1_first.players.values_list('id', flat=True))
        if t2_first:
            cup_blue_pids = list(t2_first.players.values_list('id', flat=True))

    for match in matches:
        t1 = next((t for t in match.teams.all() if t.team_number == 1), None)
        t2 = next((t for t in match.teams.all() if t.team_number == 2), None)
        team1_pids = list(t1.players.values_list('id', flat=True)) if t1 else []
        team2_pids = list(t2.players.values_list('id', flat=True)) if t2 else []

        # Tally cup points per decided match.  Most TC formats award
        # 1 point per match (4-player 2v2 = 4 matches × 1 = 4 pts;
        # 2v1 = 4 matches × 1 = 4 pts).  2-player TC is a Nassau
        # F9/B9/Overall with point values 1/1/2 — the Overall match
        # is the marquee bet, weighted 2× — so total cup contribution
        # still equals 4 pts per foursome.  Money is settled ONCE at
        # the cup level (below) rather than per match.
        pv = _tc_match_point_value(game.group_size, match.match_number)
        winner_label = '—'
        if match.result == 'team1':
            t1_wins   += 1
            t1_points += pv
            winner_label = 'Team 1'
        elif match.result == 'team2':
            t2_wins   += 1
            t2_points += pv
            winner_label = 'Team 2'
        elif match.result == 'halved' or match.status == MatchStatus.HALVED:
            halves    += 1
            t1_points += pv / 2
            t2_points += pv / 2
            winner_label = 'Halved'

        # Display end hole = actually played hole if clinched early.
        hole_rows = list(match.hole_results.all())
        if (match.status in (MatchStatus.COMPLETE, MatchStatus.HALVED)
                and hole_rows
                and hole_rows[-1].hole_number < match.end_hole):
            display_end = hole_rows[-1].hole_number
        else:
            display_end = match.end_hole

        # Per-hole rows include par + stroke index + each player's
        # gross/strokes/net + team-level alt-shot strokes so the
        # leaderboard can render a Nassau-style detail grid per
        # segment without joining against the scorecard endpoint.
        match_pids   = list(team1_pids) + list(team2_pids)
        match_index  = pair_indexes.get(match.id, net_index)

        # Expected strokes per player per hole — same numbers the
        # entry-screen dot display reads, the leaderboard per-player
        # stroke dots use, AND we surface as `strokes` on scored hole
        # entries so a hole's dots don't change after scoring.
        expected = _expected_strokes_per_match(
            match, matches, team1_pids, team2_pids,
            game, members_by_pid, foursome_low_pid,
        )

        # Foursomes team-row dots come from the dedicated team-vs-team
        # SO calc.  For other segments (and NET mode) they're null on
        # the hole entries.
        t1_team_strokes_by_hole: dict = {}
        t2_team_strokes_by_hole: dict = {}
        if match.segment == 'foursomes':
            seg_range = range(match.start_hole, match.end_hole + 1)
            t1_team_strokes_by_hole, t2_team_strokes_by_hole = (
                _foursomes_team_strokes(
                    game, team1_pids, team2_pids, members_by_pid, seg_range,
                )
            )

        def _team_gross_for(team_pids, hole):
            grosses = [gross_index[p][hole] for p in team_pids
                       if p in gross_index and hole in gross_index[p]]
            return min(grosses) if grosses else None

        holes_out = []
        for hr in hole_rows:
            if hr.winning_team_number == 1:
                hole_winner = 'T1'
            elif hr.winning_team_number == 2:
                hole_winner = 'T2'
            else:
                hole_winner = 'Halved'
            scores_for_hole = []
            for pid in match_pids:
                gross = gross_index.get(pid, {}).get(hr.hole_number)
                net   = match_index.get(pid, {}).get(hr.hole_number)
                # Strokes reflect the segment-specific expected
                # allocation (matches what the entry-screen dots
                # showed before scoring) — not gross−net, which can
                # disagree when alt-shot mixes player gross with
                # team handicap.
                strokes = expected.get(pid, {}).get(hr.hole_number, 0)
                scores_for_hole.append({
                    'player_id': pid,
                    'gross'    : gross,
                    'strokes'  : strokes,
                    'net'      : net,
                })
            holes_out.append({
                'hole'           : hr.hole_number,
                'par'            : par_by_hole.get(hr.hole_number),
                'stroke_index'   : si_by_hole.get(hr.hole_number),
                't1_net'         : hr.team1_net,
                't2_net'         : hr.team2_net,
                't1_team_gross'  : _team_gross_for(team1_pids, hr.hole_number)
                                    if match.segment == 'foursomes' else None,
                't2_team_gross'  : _team_gross_for(team2_pids, hr.hole_number)
                                    if match.segment == 'foursomes' else None,
                't1_team_strokes': t1_team_strokes_by_hole.get(hr.hole_number)
                                    if match.segment == 'foursomes' else None,
                't2_team_strokes': t2_team_strokes_by_hole.get(hr.hole_number)
                                    if match.segment == 'foursomes' else None,
                'winner'         : hole_winner,
                'margin'         : hr.holes_up_after,
                'scores'         : scores_for_hole,
            })

        # Flat player roster for the match — every player with their team
        # number, used by the leaderboard to render rows in team colors.
        # `strokes_off` semantics:
        #   • Foursomes (SO mode): team alt-shot differential — both
        #     partners on the higher-combined team carry the same value;
        #     both partners on the lower team carry 0.
        #   • Singles / Fourball (SO mode): per-player differential vs
        #     the relevant baseline (foursome low for most matches,
        #     per-pair low for the SO-reset singles).
        #   • NET / GROSS mode: null (no SO concept).
        so_baseline_low = None
        team_so_t1 = team_so_t2 = None
        if game.handicap_mode == HandicapMode.STROKES_OFF:
            if match.segment == 'foursomes':
                c1, _ = _alt_shot_team_combined(game, team1_pids, members_by_pid)
                c2, _ = _alt_shot_team_combined(game, team2_pids, members_by_pid)
                if c1 <= c2:
                    team_so_t1, team_so_t2 = 0, c2 - c1
                else:
                    team_so_t1, team_so_t2 = c1 - c2, 0
            else:
                so_baseline_low = _so_baseline_for_match(
                    match, team1_pids, team2_pids, members_by_pid,
                    pair_indexes,
                )
        # Per-hole SO for the cross-foursome fourball (donor-inclusive low),
        # so the "-N" badge tracks the rotating donor hole-by-hole instead of
        # a single per-segment value.  Empty for every other match.
        so_by_hole_map = _fourball_donor_so_by_hole(
            match, team1_pids, team2_pids, members_by_pid, game,
        )
        players_out = []
        for team_num, pids in ((1, team1_pids), (2, team2_pids)):
            for pid in pids:
                m = members_by_pid.get(pid)
                if m is None:
                    continue
                so_val = None
                if team_so_t1 is not None:
                    # Foursomes — team SO applies to both partners.
                    so_val = team_so_t1 if team_num == 1 else team_so_t2
                elif so_baseline_low is not None and m.playing_handicap is not None:
                    so_val = max(0, m.playing_handicap - so_baseline_low)
                players_out.append({
                    'player_id'        : pid,
                    'name'             : m.player.name,
                    'short_name'       : m.player.short_name or m.player.name[:5],
                    'team_number'      : team_num,
                    'is_phantom'       : m.player.is_phantom,
                    'playing_handicap' : m.playing_handicap,
                    'strokes_off'      : so_val,
                    # {hole: strokes} for this player in this match's
                    # hole range.  Score-entry dots read directly from
                    # here so they show the right count even before
                    # any score is entered.
                    'strokes_by_hole'  : expected.get(pid, {}),
                    # {hole: SO} — non-empty only for the cross-foursome
                    # fourball; lets the badge show the per-hole SO that
                    # matches the dots.  Falls back to strokes_off otherwise.
                    'so_by_hole'       : so_by_hole_map.get(pid, {}),
                })

        matches_out.append({
            'match_number'    : match.match_number,
            'segment'         : match.segment,
            'label'           : match.label or match.get_segment_display(),
            'start_hole'      : match.start_hole,
            'end_hole'        : match.end_hole,
            'display_end_hole': display_end,
            'status'          : match.status,
            'result'          : match.result,
            'finished_on_hole': match.finished_on_hole,
            'holes_up_final'  : match.holes_up_after_final,
            'winner_label'    : winner_label,
            # Alt-shot first-tee assignments — only set for foursomes
            # matches; null elsewhere.  Mobile uses these to derive
            # which player is "active" on each hole (alternation by
            # hole parity) and dims the partner.
            'team1_first_tee_id': match.team1_first_tee_player_id,
            'team2_first_tee_id': match.team2_first_tee_player_id,
            'team1' : {
                'players': _player_names(team1_pids, members_by_pid),
                'shorts' : _player_shorts(team1_pids, members_by_pid),
            },
            'team2' : {
                'players': _player_names(team2_pids, members_by_pid),
                'shorts' : _player_shorts(team2_pids, members_by_pid),
            },
            'players' : players_out,
            'holes'   : holes_out,
        })

    # Cup-level settlement: one bet_unit per real player on the
    # losing side flows to each player on the winning side.  Halved
    # cup (and any state where neither side leads on points) → wash.
    # Money tracks the CURRENT projected payout, so the display
    # updates as cup points shift during play.
    for m in foursome.memberships.select_related('player').all():
        if m.player.is_phantom:
            continue
        money_totals.setdefault(
            m.player_id,
            {'name': m.player.name, 'amount': 0.0},
        )

    if t1_points != t2_points:
        winners = cup_red_pids if t1_points > t2_points else cup_blue_pids
        losers  = cup_blue_pids if t1_points > t2_points else cup_red_pids
        for pid in winners:
            entry = money_totals.get(pid)
            if entry is not None:
                entry['amount'] = bet_unit
        for pid in losers:
            entry = money_totals.get(pid)
            if entry is not None:
                entry['amount'] = -bet_unit

    money_out = sorted(
        money_totals.values(),
        key=lambda e: (-e['amount'], e['name']),
    )

    # Cup TournamentTeam colours (e.g. "Red", "Blue", "Green") so the
    # score-entry + leaderboard UIs can render this foursome's
    # team rows in the actual cup team colours instead of the
    # generic casual red/blue.  Null on casual rounds.
    team1_colour = None
    team2_colour = None
    team1_name = None
    team2_name = None
    try:
        cfg = foursome.ryder_cup_foursome_config
        if cfg.team1 is not None:
            team1_colour = cfg.team1.colour
            team1_name   = cfg.team1.name
        if cfg.team2 is not None:
            team2_colour = cfg.team2.colour
            team2_name   = cfg.team2.name
    except Exception:
        pass

    # Cross-foursome phantom donor info — populated only for 2v1 TC
    # where the solo's fourball partner is a scratch phantom pulling
    # net scores from another foursome's same-team players.  Mobile
    # uses this to label the phantom row "Phantom (Glenn)" and surface
    # a "Waiting for Glenn..." placeholder when the donor hasn't
    # posted that hole yet.  Same shape nassau exposes.
    from scoring.phantom import build_phantom_info
    phantom_info = build_phantom_info(foursome, game.net_percent)

    return {
        'status'     : game.status,
        'group_size' : game.group_size,
        'team1_colour': team1_colour,
        'team2_colour': team2_colour,
        'team1_name'  : team1_name,
        'team2_name'  : team2_name,
        'handicap'   : {
            'mode'              : game.handicap_mode,
            'net_percent'       : game.net_percent,
            'alt_shot_low_pct'  : game.alt_shot_low_pct,
            'alt_shot_high_pct' : game.alt_shot_high_pct,
        },
        'matches' : matches_out,
        'overall' : {
            'team1_wins'      : t1_wins,
            'team2_wins'      : t2_wins,
            'halves'          : halves,
            'team1_points'    : t1_points,
            'team2_points'    : t2_points,
            # Sum of per-match point values — always whole (4 per
            # foursome: 4×1 for 2v2/2v1, or 1+1+2 for 2-player Nassau).
            # Coerce to int so the mobile model's `int?` cast on
            # `points_available` doesn't blow up — _tc_match_point_value
            # returns float (1.0 / 2.0) which sums as double on the
            # wire.
            'points_available': int(sum(
                _tc_match_point_value(game.group_size, m.match_number)
                for m in matches
            )),
        },
        'money' : {
            'bet_unit'  : bet_unit,
            'by_player' : money_out,
        },
        'phantom' : phantom_info,
    }


