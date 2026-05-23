"""
services/cup_change_game.py
---------------------------
Swap the cup game for a Round without rebuilding its foursomes.

Real-world need: cup tournaments often shift formats day-to-day —
Day 1 might be Singles Nassau, Day 2 might flip to Four Ball.  The
original RyderCupRoundSetupView wipes and re-builds every foursome
from scratch; this helper takes the much cheaper path of keeping
the FoursomeMembership rows + team assignments intact and just
swapping out the per-foursome game model.

Supported swaps
~~~~~~~~~~~~~~~
Any combination of these four (the games that share the same
4-player team-vs-team structure):
    nassau          (2v2 best-ball)
    quota_nassau    (2v2 stableford-vs-quota)
    singles_nassau  (1v1 nassau, 2 matches per foursome)
    singles_18      (1v1 18-hole overall)

Cross-team teaming and singles matchups are derived from each
player's TournamentTeam membership (set during the cup draft):
  → 2v2 games:        team_a's players  → team1,  team_b's players → team2
  → singles games:    auto-pair by handicap rank within each team
                      (setup_cup_singles already does this)

Out of scope (raises NotImplementedError)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    irish_rumble   — needs explicit cross-foursome pairings
    match_play     — separate bracket-driven flow
For those, use the full Cup Round Setup wizard.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from rest_framework import serializers

from core.models import GameType


# Games this helper can swap between.  Any game outside this set
# must go through the full setup wizard instead.
_SWAPPABLE = {
    GameType.NASSAU,
    GameType.QUOTA_NASSAU,
    GameType.SINGLES_NASSAU,
    GameType.SINGLES_18,
}


def change_round_game(round_obj, *, game_type: str,
                      point_value: Decimal | None = None) -> dict:
    """
    Swap every foursome in `round_obj`'s cup config to `game_type`.

    Returns a dict summary:
        {
          'changed': int,    # number of foursomes updated
          'skipped': list,   # group numbers we couldn't auto-team
        }

    Raises ValidationError on bad input or unsupported game.
    """
    from games.models import (
        MatchPlayBracket, NassauGame, QuotaNassauGame,
    )
    from tournament.models import (
        FoursomeMembership, RyderCupFoursomeConfig, RyderCupRoundConfig,
        TournamentTeam,
    )

    try:
        gtype = GameType(game_type)
    except ValueError:
        raise serializers.ValidationError({
            'game_type': f'Unknown game type "{game_type}".',
        })
    if gtype not in _SWAPPABLE:
        raise NotImplementedError(
            f'change_round_game does not yet support "{game_type}".  '
            f'Supported: {sorted(_SWAPPABLE)}.  Use the full Cup Round '
            'Setup wizard for unsupported games.'
        )

    try:
        rc = RyderCupRoundConfig.objects.select_related('tournament').get(
            round=round_obj,
        )
    except RyderCupRoundConfig.DoesNotExist:
        raise serializers.ValidationError({
            'detail': 'This round has no cup config to change.  Use '
                      'Set Up Cup Round first.',
        })

    fs_configs = list(
        RyderCupFoursomeConfig.objects
        .filter(round_config=rc)
        .select_related('foursome', 'team1', 'team2')
        .prefetch_related('foursome__memberships__player')
    )
    if not fs_configs:
        raise serializers.ValidationError({
            'detail': 'No foursomes are configured for this round.',
        })

    # Tournament teams used to assign players when going to a
    # team-vs-team game.  Cache the player→team lookup once.
    teams = list(
        TournamentTeam.objects
        .filter(tournament=rc.tournament)
        .prefetch_related('players')
    )
    if len(teams) < 2:
        raise serializers.ValidationError({
            'detail': 'This tournament needs at least two teams to '
                      'change cup games — finish the draft first.',
        })
    player_to_team = {
        p_id: t.id
        for t in teams
        for p_id in t.players.values_list('id', flat=True)
    }

    changed = 0
    skipped = []

    with transaction.atomic():
        for fc in fs_configs:
            fs = fc.foursome
            # Real players in this foursome, grouped by their
            # TournamentTeam membership.
            real_memberships = [
                m for m in fs.memberships.all()
                if not m.player.is_phantom
            ]
            buckets: dict[int, list[FoursomeMembership]] = {}
            for m in real_memberships:
                tid = player_to_team.get(m.player_id)
                if tid is None:
                    continue
                buckets.setdefault(tid, []).append(m)

            team_ids_present = sorted(buckets.keys())
            if len(team_ids_present) < 2:
                # Single-team or untagged foursome — can't auto-team it
                # for a head-to-head game.  Skip with a note.
                skipped.append(fs.group_number)
                continue

            # Use the two teams with the most players in this foursome.
            sorted_buckets = sorted(
                buckets.items(),
                key=lambda kv: (-len(kv[1]), kv[0]),
            )
            ta_id, ta_members = sorted_buckets[0]
            tb_id, tb_members = sorted_buckets[1]
            team_a = next(t for t in teams if t.id == ta_id)
            team_b = next(t for t in teams if t.id == tb_id)
            t1_ids = [m.player_id for m in ta_members]
            t2_ids = [m.player_id for m in tb_members]

            # ── Wipe whichever game model the foursome currently has,
            #    then build the requested one.  We do all four
            #    deletes unconditionally because a previous swap could
            #    have left rows behind in any of them.
            NassauGame.objects.filter(foursome=fs).delete()
            QuotaNassauGame.objects.filter(foursome=fs).delete()
            MatchPlayBracket.objects.filter(
                foursome=fs, bracket_type='cup_singles',
            ).delete()
            # singles_18 also uses MatchPlayBracket — same delete covers it.

            if gtype in (GameType.NASSAU,):
                from services.nassau import setup_nassau
                # Inherit the round's handicap mode so the per-game
                # setup matches the round-wide rule.
                setup_nassau(
                    fs, t1_ids, t2_ids,
                    handicap_mode=round_obj.handicap_mode,
                    net_percent=round_obj.net_percent,
                )
            elif gtype == GameType.QUOTA_NASSAU:
                from services.quota_nassau import setup_quota_nassau
                pairings = _build_quota_pairings(
                    fs, ta_members, tb_members,
                )
                if pairings:
                    setup_quota_nassau(fs, pairings)
            elif gtype in (GameType.SINGLES_NASSAU, GameType.SINGLES_18):
                from services.cup_singles import setup_cup_singles
                setup_cup_singles(fs, team_a, team_b)

            # Update the per-foursome config to point at the new game.
            fc.game_type = str(gtype)
            if point_value is not None:
                fc.point_value = point_value
            fc.team1 = team_a
            fc.team2 = team_b
            fc.save(update_fields=['game_type', 'point_value',
                                   'team1', 'team2'])
            changed += 1

    # Recalculate any standings that depend on the new game shape.
    try:
        from services.ryder_cup import calculate_ryder_cup_points
        calculate_ryder_cup_points(round_obj)
    except Exception:
        # The cup standings refresh is best-effort; the swap itself
        # has already committed.  The recalc endpoint can be hit
        # manually to fix this up.
        pass

    return {'changed': changed, 'skipped': skipped}


def _build_quota_pairings(fs, ta_members, tb_members) -> list[dict]:
    """
    Quota Nassau wants 1-on-1 cross-team pairings with each player's
    quota = 36 − course_handicap.  Pair by handicap rank within each
    team, top-vs-top, bottom-vs-bottom.
    """
    a = sorted(ta_members, key=lambda m: m.course_handicap or 0)
    b = sorted(tb_members, key=lambda m: m.course_handicap or 0)
    pairs = []
    for m1, m2 in zip(a, b):
        pairs.append({
            'player1_id'   : m1.player_id,
            'player2_id'   : m2.player_id,
            'player1_quota': max(0, 36 - (m1.course_handicap or 0)),
            'player2_quota': max(0, 36 - (m2.course_handicap or 0)),
        })
    return pairs
