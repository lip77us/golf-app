"""
api/views.py
------------
All API views for the Golf App.

Endpoint map
~~~~~~~~~~~~
Auth
  POST   /api/auth/login/                  LoginView
  POST   /api/auth/logout/                 LogoutView
  GET    /api/auth/me/                     MeView

Reference data
  GET    /api/players/                     PlayerListView
  GET    /api/tees/                        TeeListView

Tournaments
  GET    /api/tournaments/                 TournamentListView
  POST   /api/tournaments/                 TournamentListView
  GET    /api/tournaments/{id}/            TournamentDetailView

Rounds
  POST   /api/rounds/                      RoundCreateView
  GET    /api/rounds/{id}/                 RoundDetailView
  POST   /api/rounds/{id}/setup/           RoundSetupView

Foursomes & scoring
  GET    /api/foursomes/{id}/              FoursomeDetailView
  GET    /api/foursomes/{id}/scorecard/    ScorecardView
  POST   /api/foursomes/{id}/scores/       ScoreSubmitView

Leaderboard
  GET    /api/rounds/{id}/leaderboard/     LeaderboardView

Nassau game
  POST   /api/foursomes/{id}/nassau/setup/ NassauSetupView
  GET    /api/foursomes/{id}/nassau/       NassauResultView

Six's game
  POST   /api/foursomes/{id}/sixes/setup/  SixesSetupView
  GET    /api/foursomes/{id}/sixes/        SixesResultView

Match Play
  GET    /api/foursomes/{id}/match-play/   MatchPlayResultView
"""

from django.contrib.auth import authenticate
from django.http import JsonResponse
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.views.decorators.csrf import csrf_exempt

from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.permissions import AllowAny, IsAuthenticated

from core.models import Player, Tee, Course, HandicapMode, GameType
from tournament.models import Tournament, Round, Foursome, FoursomeMembership
from scoring.models import HoleScore
from scoring.phantom import PhantomScoreProvider, get_algorithm, DEFAULT_ALGORITHM_ID

from .serializers import (
    PlayerSerializer, PlayerCreateSerializer, TeeSerializer,
    TournamentSerializer, RoundSerializer, FoursomeSerializer,
    ScoreSubmitSerializer, RoundSetupSerializer,
    TournamentCreateSerializer, RoundCreateSerializer,
    NassauSetupSerializer, NassauPressSerializer,
    SixesSetupSerializer, CourseSerializer,
    Points531SetupSerializer, CasualRoundSummarySerializer,
    IrishRumbleSetupSerializer, LowNetSetupSerializer,
    ThreePersonMatchSetupSerializer,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _recalculate_games(foursome: Foursome) -> None:
    """
    Run every active game calculator for the given foursome's round.
    Per-foursome games: skins, sixes, nassau, match_play.
    Per-round games:    stableford, pink_ball, low_net_round, irish_rumble, scramble.
    Safe to call after every score update — all calculators are idempotent.

    Active games resolution: union of round-level and foursome-level games.
    Round-level games (stableford, irish_rumble, pink_ball, stroke_play) apply
    to every foursome.  Per-foursome games (match_play, nassau, skins, sixes)
    are stored on the foursome itself.  Both sets must be recalculated so that
    a round combining e.g. match_play + irish_rumble correctly updates both.
    """
    round_obj    = foursome.round
    active_games = list(
        set(foursome.active_games or []) | set(round_obj.active_games or [])
    )

    # ---- Per-foursome ----
    if 'skins' in active_games:
        from services.skins import calculate_skins
        calculate_skins(foursome)

    if 'sixes' in active_games:
        from services.sixes import calculate_sixes
        calculate_sixes(foursome)

    if 'nassau' in active_games:
        from services.nassau import calculate_nassau
        calculate_nassau(foursome)

    # Tournament-level games (match_play, three_person_match) live on
    # tournament.active_games rather than the round or foursome, so they may
    # not appear in active_games even when a bracket/record exists.  Check
    # for a DB row as a reliable fallback — the setup views now also stamp
    # foursome.active_games so future setups don't need the fallback, but
    # existing rows created before that fix must still be handled.
    if 'match_play' in active_games or foursome.match_play_brackets.exists():
        # Route to the correct calculator based on bracket type.
        bracket = foursome.match_play_brackets.first()
        if bracket and bracket.bracket_type == 'cup_singles':
            from services.cup_singles import calculate_cup_singles
            calculate_cup_singles(foursome)
        else:
            from services.tournament_match_play import calculate_tournament_match_play
            calculate_tournament_match_play(foursome)

    # Non-cup casual singles (singles_nassau / singles_18) — use 1-v-1 18-hole
    # cup_singles bracket format so the leaderboard can show the same card as
    # Bandon Cup.  Auto-create the bracket on first score submission if needed.
    _casual_singles_key = (
        'singles_nassau' if 'singles_nassau' in active_games else
        'singles_18'     if 'singles_18'     in active_games else
        None
    )
    if _casual_singles_key and 'match_play' not in active_games:
        _is_cup_fs = False
        try:
            _ = foursome.ryder_cup_foursome_config
            _is_cup_fs = True
        except Exception:
            pass
        if not _is_cup_fs:
            from services.cup_singles import setup_cup_singles, calculate_cup_singles
            if not foursome.match_play_brackets.filter(bracket_type='cup_singles').exists():
                try:
                    setup_cup_singles(foursome, None, None, singles_matchups=[])
                except (ValueError, Exception):
                    pass
            calculate_cup_singles(foursome)

    if 'points_531' in active_games:
        from services.points_531 import calculate_points_531
        calculate_points_531(foursome)

    from games.models import ThreePersonMatch as _TPM
    _tpm_in_games = 'three_person_match' in active_games
    _tpm_exists   = _TPM.objects.filter(foursome=foursome).exists()
    if _tpm_in_games or _tpm_exists:
        from services.three_person_match import calculate_three_person_match
        calculate_three_person_match(foursome)

    # ---- Per-round ----
    if 'stableford' in active_games:
        from services.stableford import calculate_stableford
        calculate_stableford(round_obj)

    if 'pink_ball' in active_games:
        from services.red_ball import calculate_red_ball
        calculate_red_ball(round_obj)

    if 'irish_rumble' in active_games:
        from services.irish_rumble import calculate_irish_rumble
        calculate_irish_rumble(round_obj)

    if 'scramble' in active_games:
        from services.scramble import calculate_scramble
        calculate_scramble(round_obj)

    if 'quota_nassau' in active_games:
        from services.quota_nassau import calculate_quota_nassau
        calculate_quota_nassau(foursome)

    # ── Ryder Cup points ───────────────────────────────────────────────────────
    # Auto-recalculate cup points whenever any game result changes so the
    # scoreboard stays current without requiring a manual trigger.
    try:
        _ = round_obj.ryder_cup_config   # raises DoesNotExist for non-cup rounds
        from services.ryder_cup import calculate_ryder_cup_points
        calculate_ryder_cup_points(round_obj)
    except Exception:
        pass  # not a cup round — skip silently


def _build_scorecard(foursome: Foursome) -> dict:
    """Build the scorecard dict for a foursome."""
    memberships  = list(foursome.memberships.select_related('player', 'tee').all())
    real_members = [m for m in memberships if not m.player.is_phantom]

    # Hole metadata (par, stroke_index, yards) lives on Tee.holes, not on
    # Course. Round has no direct FK to Tee, so use a representative Tee from
    # the memberships. Par and stroke_index are typically identical across
    # tees at the same course; yardage will reflect the chosen membership's tee.
    first_with_tee = next((m for m in memberships if m.tee_id), None)
    if first_with_tee is None:
        return {
            'foursome_id' : foursome.id,
            'group_number': foursome.group_number,
            'holes'       : [],
            'totals'      : [],
        }
    tee = first_with_tee.tee

    score_map = {}
    for hs in HoleScore.objects.filter(foursome=foursome).select_related('player'):
        score_map[(hs.player_id, hs.hole_number)] = hs

    holes_out = []
    for hole_dict in sorted(tee.holes, key=lambda h: h['number']):
        hole_num     = hole_dict['number']
        stroke_index = hole_dict.get('stroke_index', 18)
        scores_for_hole = []
        for m in real_members:
            hs = score_map.get((m.player_id, hole_num))
            # For unplayed holes we predict handicap_strokes from the player's
            # OWN tee SI (can differ from the representative tee's SI on
            # courses with separate men's/women's allocations).
            if m.tee_id is not None:
                m_hole_info = m.tee.hole(hole_num)
                m_si        = m_hole_info.get('stroke_index', stroke_index)
                m_par       = m_hole_info.get('par', hole_dict.get('par', 4))
                m_yards     = m_hole_info.get('yards')
            else:
                m_si    = stroke_index
                m_par   = hole_dict.get('par', 4)
                m_yards = hole_dict.get('yards')
            scores_for_hole.append({
                'player_id'        : m.player_id,
                'player_name'      : m.player.name,
                'hole_number'      : hole_num,
                # THIS PLAYER'S OWN tee attributes on this hole — needed on
                # the client for mixed men's/women's foursomes where par,
                # yards, and SI commonly differ by tee.  The shared
                # `hole.par/yards/stroke_index` reflect only the first
                # player's tee, so without these the hole header shows
                # one player's numbers for everyone.
                'stroke_index'     : m_si,
                'par'              : m_par,
                'yards'            : m_yards,
                'gross_score'      : hs.gross_score       if hs else None,
                'handicap_strokes' : hs.handicap_strokes  if hs else m.handicap_strokes_on_hole(m_si),
                'net_score'        : hs.net_score         if hs else None,
                'stableford_points': hs.stableford_points if hs else None,
            })
        holes_out.append({
            'hole_number' : hole_num,
            'par'         : hole_dict['par'],
            'stroke_index': stroke_index,
            'yards'       : hole_dict.get('yards'),
            'scores'      : scores_for_hole,
        })

    # Inject phantom hole scores
    if foursome.has_phantom:
        from scoring.phantom import CROSS_FOURSOME_ALGORITHM_ID
        provider = PhantomScoreProvider(foursome)
        if provider.has_phantom:
            phantom_gross = provider.phantom_gross_scores()

            # For cross-foursome phantoms, include the phantom as a regular
            # score entry in each hole's `scores` list so the Flutter client
            # can detect when their score has arrived and block hole
            # submission accordingly.
            if provider.is_cross_foursome:
                phantom_m = foursome.memberships.filter(
                    player__is_phantom=True
                ).select_related('player', 'tee').first()
                if phantom_m:
                    phantom_si_map = {}
                    if phantom_m.tee_id:
                        for hd in phantom_m.tee.holes:
                            phantom_si_map[hd['number']] = hd.get('stroke_index', 18)

                    for h in holes_out:
                        hole_num   = h['hole_number']
                        gross      = phantom_gross.get(hole_num)
                        ph_si      = phantom_si_map.get(hole_num, 18)
                        ph_strokes = phantom_m.handicap_strokes_on_hole(ph_si)
                        h['scores'].append({
                            'player_id'        : phantom_m.player_id,
                            'player_name'      : phantom_m.player.name,
                            'hole_number'      : hole_num,
                            'stroke_index'     : ph_si,
                            'par'              : h['par'],
                            'yards'            : None,
                            'gross_score'      : gross,
                            'handicap_strokes' : ph_strokes,
                            'net_score'        : (gross - ph_strokes) if gross is not None else None,
                            'stableford_points': None,
                            'is_phantom'       : True,
                        })
                        if hole_num in phantom_gross:
                            h['phantom'] = {
                                'gross_score'             : phantom_gross[hole_num],
                                'is_phantom'              : True,
                                'phantom_source_player_id': provider.get_source_player_id(hole_num),
                            }
            else:
                # Intra-foursome phantom: legacy h['phantom'] only
                for h in holes_out:
                    hole_num = h['hole_number']
                    if hole_num in phantom_gross:
                        h['phantom'] = {
                            'gross_score'             : phantom_gross[hole_num],
                            'is_phantom'              : True,
                            'phantom_source_player_id': provider.get_source_player_id(hole_num),
                        }

    totals = []
    for m in real_members:
        fg = bg = fn = bn = sf = 0
        for (pid, hnum), hs in score_map.items():
            if pid != m.player_id or hs.gross_score is None:
                continue
            if 1 <= hnum <= 9:
                fg += hs.gross_score or 0
                fn += hs.net_score   or 0
            else:
                bg += hs.gross_score or 0
                bn += hs.net_score   or 0
            sf += hs.stableford_points or 0
        totals.append({
            'player_id'       : m.player_id,
            'name'            : m.player.name,
            'front_gross'     : fg,
            'back_gross'      : bg,
            'total_gross'     : fg + bg,
            'front_net'       : fn,
            'back_net'        : bn,
            'total_net'       : fn + bn,
            'total_stableford': sf,
        })

    return {
        'foursome_id' : foursome.id,
        'group_number': foursome.group_number,
        'holes'       : holes_out,
        'totals'      : totals,
    }


def _build_leaderboard(round_obj: Round) -> dict:
    """Call each active game's summary and return a dict keyed by game type."""
    active_games = round_obj.active_games or []
    foursomes    = list(round_obj.foursomes.all())
    games        = {}

    if 'skins' in active_games:
        from services.skins import skins_summary
        games['skins'] = {
            'label'   : 'Skins',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': skins_summary(fs)}
                for fs in foursomes
            ],
        }

    if 'stableford' in active_games:
        from services.stableford import stableford_summary
        games['stableford'] = {
            'label'  : 'Stableford',
            'results': stableford_summary(round_obj),
        }

    if 'pink_ball' in active_games:
        from services.red_ball import red_ball_summary
        games['pink_ball'] = {
            'label': 'Pink Ball',
            **red_ball_summary(round_obj),
        }

    if 'low_net_round' in active_games:
        from services.low_net_round import low_net_round_summary
        games['low_net_round'] = {
            'label': 'Low Net',
            **low_net_round_summary(round_obj),
        }

    if 'irish_rumble' in active_games:
        from services.irish_rumble import irish_rumble_summary
        from tournament.models import RyderCupIrishRumblePairing
        # Check for cup-mode Irish Rumble (head-to-head pairings between
        # foursomes from opposing teams).  If pairings exist we display the
        # matchup results instead of the standard segment-ranking table.
        cup_ir_pairings = []
        try:
            rc = round_obj.ryder_cup_config
            cup_ir_pairings = list(
                RyderCupIrishRumblePairing.objects
                .filter(round_config=rc)
                .select_related('foursome_a', 'foursome_b', 'team_a', 'team_b')
            )
        except Exception:
            pass
        if cup_ir_pairings:
            pairings_out = []
            for p in cup_ir_pairings:
                pairings_out.append({
                    'foursome_a_id'  : p.foursome_a_id,
                    'group_a'        : p.foursome_a.group_number,
                    'team_a'         : p.team_a.name   if p.team_a else '',
                    'team_a_colour'  : p.team_a.colour if p.team_a else '',
                    'foursome_b_id'  : p.foursome_b_id,
                    'group_b'        : p.foursome_b.group_number,
                    'team_b'         : p.team_b.name   if p.team_b else '',
                    'team_b_colour'  : p.team_b.colour if p.team_b else '',
                    'front9_result'  : p.front9_result,
                    'back9_result'   : p.back9_result,
                    'overall_result' : p.overall_result,
                })
            games['irish_rumble'] = {
                'label'   : 'Irish Rumble',
                'is_cup'  : True,
                'pairings': pairings_out,
            }
        else:
            summary = irish_rumble_summary(round_obj)
            # For cup rounds, remove non-IR foursomes from the rankings so
            # that groups playing Singles / Quota Nassau / etc. don't appear
            # on the Irish Rumble leaderboard tab.
            ir_groups = set()
            for fs in foursomes:
                try:
                    if fs.ryder_cup_foursome_config.game_type == GameType.IRISH_RUMBLE:
                        ir_groups.add(f"Group {fs.group_number}")
                except Exception:
                    pass
            if ir_groups:
                for seg in summary.get('segments', []):
                    seg['results'] = [
                        r for r in seg.get('results', [])
                        if r.get('group') in ir_groups
                    ]
                summary['overall'] = [
                    r for r in summary.get('overall', [])
                    if r.get('group') in ir_groups
                ]
            games['irish_rumble'] = {
                'label': 'Irish Rumble',
                **summary,
            }

    if 'scramble' in active_games:
        from services.scramble import scramble_summary
        games['scramble'] = {
            'label'  : 'Scramble',
            'results': scramble_summary(round_obj),
        }

    if 'sixes' in active_games:
        from services.sixes import sixes_summary
        games['sixes'] = {
            'label'   : "Six's",
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': sixes_summary(fs)}
                for fs in foursomes
            ],
        }

    if 'nassau' in active_games:
        from services.nassau import nassau_summary
        nassau_groups = []
        for fs in foursomes:
            # For cup rounds, skip foursomes assigned to a different game type
            cup_cfg = None
            try:
                cup_cfg = fs.ryder_cup_foursome_config
                if cup_cfg.game_type != GameType.NASSAU:
                    continue  # Skip; this foursome plays singles/IR/skins/etc.
            except Exception:
                pass  # Not a cup foursome — include normally

            group_entry = {
                'foursome_id' : fs.id,
                'group_number': fs.group_number,
                'summary'     : nassau_summary(fs),
            }
            # Augment with cup metadata if this is a cup nassau match
            if cup_cfg is not None:
                t1 = cup_cfg.team1
                t2 = cup_cfg.team2
                group_entry['is_cup_match']     = True
                group_entry['cup_point_value']  = float(cup_cfg.point_value)
                group_entry['team1_name']       = t1.name             if t1 else ''
                group_entry['team2_name']       = t2.name             if t2 else ''
                group_entry['team1_colour']     = (t1.colour or 'Red')  if t1 else 'Red'
                group_entry['team2_colour']     = (t2.colour or 'Blue') if t2 else 'Blue'
            nassau_groups.append(group_entry)
        games['nassau'] = {
            'label'   : 'Four Ball',
            'by_group': nassau_groups,
        }

    # Quota Nassau — also check per-foursome active_games for cup rounds
    _qn_active = 'quota_nassau' in active_games or any(
        'quota_nassau' in (fs.active_games or []) for fs in foursomes
    )
    if _qn_active:
        from services.quota_nassau import quota_nassau_summary
        quota_groups = []
        for fs in foursomes:
            cup_cfg = None
            try:
                cup_cfg = fs.ryder_cup_foursome_config
                if cup_cfg.game_type != GameType.QUOTA_NASSAU:
                    continue   # skip foursomes assigned to a different cup game
            except Exception:
                pass  # not a cup foursome — include (casual Quota Nassau TBD)

            summary = quota_nassau_summary(fs)
            entry = {
                'foursome_id' : fs.id,
                'group_number': fs.group_number,
                'summary'     : summary,
            }
            if cup_cfg is not None:
                t1 = cup_cfg.team1
                t2 = cup_cfg.team2
                entry['is_cup_match']    = True
                entry['cup_point_value'] = float(cup_cfg.point_value)
                entry['team1_name']      = t1.name   if t1 else ''
                entry['team2_name']      = t2.name   if t2 else ''
                entry['team1_colour']    = (t1.colour or 'Red')  if t1 else 'Red'
                entry['team2_colour']    = (t2.colour or 'Blue') if t2 else 'Blue'
            quota_groups.append(entry)
        if quota_groups:
            games['quota_nassau'] = {
                'label'   : 'Quota Nassau',
                'by_group': quota_groups,
            }

    # Cup singles rounds store 'singles_18' or 'singles_nassau' in per-foursome
    # active_games rather than 'match_play' at the round level.  Trigger the
    # match_play / cup_singles processing block whenever any of these keys are
    # present, either on the round or on any of its foursomes.
    _all_fs_games = set()
    for _fs in foursomes:
        _all_fs_games.update(_fs.active_games or [])
    _mp_or_singles_active = (
        'match_play'     in active_games or
        'singles_18'     in active_games or
        'singles_nassau' in active_games or
        'singles_18'     in _all_fs_games or
        'singles_nassau' in _all_fs_games
    )
    if _mp_or_singles_active:
        from services.tournament_match_play import tournament_match_play_summary
        from services.cup_singles import cup_singles_summary
        from games.models import ThreePersonMatch as _TPM
        tpm_fs_ids = set(
            _TPM.objects
            .filter(foursome__round=round_obj)
            .values_list('foursome_id', flat=True)
        )
        mp_groups              = []
        singles_nassau_groups  = []   # cup_singles Nassau (cup rounds)
        singles_18_groups      = []   # cup_singles 18-hole (cup rounds)
        casual_sng_groups      = {}   # 'singles_nassau' | 'singles_18' → list
        for fs in foursomes:
            if fs.id in tpm_fs_ids:
                continue  # 3-person group plays 5-3-1, not bracket match play
            # For cup rounds, route each foursome to the correct section based
            # on its assigned game type.  Non-cup foursomes go to match_play
            # or casual singles depending on their active games.
            cup_game_type = None
            cup_cfg       = None
            try:
                cup_cfg       = fs.ryder_cup_foursome_config
                cup_game_type = cup_cfg.game_type
            except Exception:
                pass

            if cup_game_type in (GameType.SINGLES_NASSAU, GameType.SINGLES_18) and cup_cfg is not None:
                # Cup singles — route Nassau and 18-hole into separate buckets
                s = cup_singles_summary(fs)
                group_entry = {
                    'foursome_id'    : fs.id,
                    'group_number'   : fs.group_number,
                    'summary'        : s,
                    'is_cup_match'   : True,
                    'cup_point_value': float(cup_cfg.point_value),
                    'team1_name'     : cup_cfg.team1.name if cup_cfg.team1 else '',
                    'team2_name'     : cup_cfg.team2.name if cup_cfg.team2 else '',
                    'team1_colour'   : (cup_cfg.team1.colour or 'Red')  if cup_cfg.team1 else 'Red',
                    'team2_colour'   : (cup_cfg.team2.colour or 'Blue') if cup_cfg.team2 else 'Blue',
                }
                if cup_game_type == GameType.SINGLES_NASSAU:
                    singles_nassau_groups.append(group_entry)
                else:
                    singles_18_groups.append(group_entry)
            elif cup_game_type is not None:
                # Cup foursome playing a different game (Nassau, Irish Rumble,
                # Skins …) — skip; it will appear in its own section.
                continue
            else:
                # Non-cup foursome: check for casual singles games first.
                _fs_all = set(round_obj.active_games or []) | set(fs.active_games or [])
                _sng_key = (
                    'singles_nassau' if 'singles_nassau' in _fs_all else
                    'singles_18'     if 'singles_18'     in _fs_all else
                    None
                )
                if _sng_key and 'match_play' not in _fs_all:
                    # Try cup_singles bracket (auto-created by _recalculate_games)
                    s = cup_singles_summary(fs)
                    if s is not None:
                        casual_sng_groups.setdefault(_sng_key, []).append({
                            'foursome_id' : fs.id,
                            'group_number': fs.group_number,
                            'summary'     : s,
                            'is_cup_match': False,
                        })
                    else:
                        # Bracket not built yet — fall back to tournament view
                        s = tournament_match_play_summary(fs)
                        mp_groups.append({
                            'foursome_id' : fs.id,
                            'group_number': fs.group_number,
                            'summary'     : s,
                        })
                else:
                    # Regular tournament match play (non-cup, non-singles)
                    s = tournament_match_play_summary(fs)
                    mp_groups.append({
                        'foursome_id' : fs.id,
                        'group_number': fs.group_number,
                        'summary'     : s,
                    })

        if mp_groups:
            games['match_play'] = {'label': 'Match Play', 'by_group': mp_groups}
        if singles_nassau_groups:
            games['cup_singles'] = {'label': 'Singles', 'by_group': singles_nassau_groups}
        if singles_18_groups:
            games['cup_singles_18'] = {'label': 'Singles-18', 'by_group': singles_18_groups}
        for _sng_key, _sng_grps in casual_sng_groups.items():
            _lbl = 'Singles Nassau' if _sng_key == 'singles_nassau' else '18-Hole Singles'
            games[_sng_key] = {'label': _lbl, 'by_group': _sng_grps}

    # Three-Person Match — always include when any foursome has one configured,
    # even if 'three_person_match' is not explicitly in round.active_games.
    from games.models import ThreePersonMatch as _TPM
    tpm_qs = (
        _TPM.objects
        .filter(foursome__round=round_obj)
        .select_related('foursome')
    )
    if tpm_qs.exists():
        from services.three_person_match import three_person_match_summary
        games['three_person_match'] = {
            'label'   : 'Three-Person Match',
            'by_group': [
                {
                    'foursome_id' : tpm.foursome_id,
                    'group_number': tpm.foursome.group_number,
                    'summary'     : three_person_match_summary(tpm.foursome),
                }
                for tpm in tpm_qs.order_by('foursome__group_number')
            ],
        }

    if 'points_531' in active_games:
        from services.points_531 import points_531_summary
        games['points_531'] = {
            'label'   : 'Points 5-3-1',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': points_531_summary(fs)}
                for fs in foursomes
            ],
        }

    return games


def _leaderboard_active_games(round_obj, games_dict: dict) -> list:
    """
    Return the active_games list for a leaderboard response.

    Starts with round_obj.active_games and appends any game keys that were
    dynamically detected (e.g. three_person_match) so the Flutter tab bar
    always reflects what's actually in the games dict.
    """
    active = list(round_obj.active_games or [])
    for key in games_dict:
        if key not in active:
            active.append(key)
    return active


def _auto_setup_games(round_obj: Round, foursomes: list) -> None:
    """
    Auto-configure per-foursome game data immediately after the draw.
    Teams are assigned by handicap rank: players ranked 1st & 3rd form
    Team 1, 2nd & 4th form Team 2 (balanced pairing).
    Called when RoundSetupView receives auto_setup_games=True.
    """
    for fs in foursomes:
        # Union of round-level and foursome-level games (same logic as
        # _recalculate_games) so that per-foursome game configs are honoured.
        active = list(
            set(round_obj.active_games or []) | set(fs.active_games or [])
        )

        members = list(
            FoursomeMembership.objects
            .filter(foursome=fs, player__is_phantom=False)
            .order_by('course_handicap')
        )
        pids = [m.player_id for m in members]
        if len(pids) < 2:
            continue

        t1 = [pids[i] for i in range(0, len(pids), 2)]   # 1st, 3rd
        t2 = [pids[i] for i in range(1, len(pids), 2)]   # 2nd, 4th

        if 'nassau' in active:
            from services.nassau import setup_nassau
            setup_nassau(fs, t1, t2)

        if 'sixes' in active and len(pids) >= 4:
            from services.sixes import setup_sixes
            setup_sixes(fs, [
                {'start_hole': 1,  'end_hole': 6,
                 'team1_player_ids': [pids[0], pids[2]],
                 'team2_player_ids': [pids[1], pids[3]],
                 'team_select_method': 'random'},
                {'start_hole': 7,  'end_hole': 12,
                 'team1_player_ids': [pids[1], pids[3]],
                 'team2_player_ids': [pids[0], pids[2]],
                 'team_select_method': 'random'},
                {'start_hole': 13, 'end_hole': 18,
                 'team1_player_ids': [pids[0], pids[3]],
                 'team2_player_ids': [pids[1], pids[2]],
                 'team_select_method': 'random'},
            ])

        if 'match_play' in active:
            real_count = len(pids)
            if real_count >= 4:
                from services.tournament_match_play import setup_tournament_match_play
                setup_tournament_match_play(fs)
            elif real_count == 3:
                # 3-player foursomes play 5-3-1 points — not a bracket.
                from services.three_person_match import setup_three_person_match
                setup_three_person_match(
                    fs,
                    handicap_mode=round_obj.handicap_mode,
                    net_percent=round_obj.net_percent,
                )
                # Stamp three_person_match in the foursome's own active_games so
                # _recalculate_games fires calculate_three_person_match on every
                # score submission without needing a DB fallback check.
                fs_games = list(fs.active_games or [])
                if 'three_person_match' not in fs_games:
                    fs_games.append('three_person_match')
                    fs.active_games = fs_games
                    fs.save(update_fields=['active_games'])


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

class LoginView(APIView):
    """
    POST /api/auth/login/
    Body: { "username": "...", "password": "..." }
    Returns:
        { "token": "...", "player": { id, name, handicap_index, is_phantom, email, phone } }
        `player` is omitted if the user has no linked Player profile (admins).

    The full player profile is returned so the client doesn't have to make
    a follow-up /auth/me/ call — that second round-trip was responsible for
    a mid-login failure mode where a transient hiccup on me() left the user
    half-logged-in and forced a re-login.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        username = request.data.get('username', '').strip()
        password = request.data.get('password', '').strip()

        if not username or not password:
            return Response(
                {'detail': 'username and password are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user = authenticate(request, username=username, password=password)
        if user is None:
            return Response(
                {'detail': 'Invalid credentials.'},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        token, _ = Token.objects.get_or_create(user=user)

        body = {'token': token.key, 'is_staff': user.is_staff}
        try:
            body['player'] = PlayerSerializer(user.player_profile).data
        except Exception:
            pass  # user has no linked Player profile
        return Response(body)


class LogoutView(APIView):
    """POST /api/auth/logout/ — invalidates the current token."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        try:
            request.user.auth_token.delete()
        except Exception:
            pass
        return Response(status=status.HTTP_204_NO_CONTENT)


class MeView(APIView):
    """GET /api/auth/me/ — current user info (is_staff + optional player profile)."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        body = {'is_staff': request.user.is_staff}
        try:
            body['player'] = PlayerSerializer(request.user.player_profile).data
        except Exception:
            body['player'] = None
        return Response(body)


# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

class PlayerListView(APIView):
    def get(self, request):
        players = Player.objects.filter(is_phantom=False).order_by('name')
        return Response(PlayerSerializer(players, many=True).data)

    def post(self, request):
        ser = PlayerCreateSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        player = ser.save()
        return Response(PlayerSerializer(player).data, status=status.HTTP_201_CREATED)


class PlayerDetailView(APIView):
    def get(self, request, pk):
        player = get_object_or_404(Player, pk=pk, is_phantom=False)
        return Response(PlayerSerializer(player).data)

    def patch(self, request, pk):
        player = get_object_or_404(Player, pk=pk, is_phantom=False)
        ser = PlayerSerializer(player, data=request.data, partial=True)
        ser.is_valid(raise_exception=True)
        player = ser.save()
        return Response(PlayerSerializer(player).data)


class CourseListView(APIView):
    def get(self, request):
        courses = Course.objects.all().order_by('name')
        return Response(CourseSerializer(courses, many=True).data)


class TeeListView(APIView):
    def get(self, request):
        tees = Tee.objects.all().order_by('course__name', 'tee_name')
        return Response(TeeSerializer(tees, many=True).data)


# ---------------------------------------------------------------------------
# Tournaments
# ---------------------------------------------------------------------------

class TournamentListView(APIView):
    def get(self, request):
        tournaments = (
            Tournament.objects
            .prefetch_related('rounds__course')
            .order_by('-start_date')
        )
        return Response(TournamentSerializer(tournaments, many=True).data)

    def post(self, request):
        """POST /api/tournaments/ — create a new tournament (staff only)."""
        if not request.user.is_staff:
            return Response(
                {'detail': 'Only staff members can create tournaments.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        ser = TournamentCreateSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data
        tournament = Tournament.objects.create(
            name         = d['name'],
            start_date   = d['start_date'],
            active_games = d['active_games'],
            total_rounds = d['total_rounds'],
        )
        return Response(TournamentSerializer(tournament).data,
                        status=status.HTTP_201_CREATED)


class TournamentDetailView(APIView):
    def get(self, request, pk):
        tournament = get_object_or_404(
            Tournament.objects.prefetch_related('rounds__course'), pk=pk
        )
        return Response(TournamentSerializer(tournament).data)

    def delete(self, request, pk):
        """DELETE /api/tournaments/{id}/ — remove tournament and all associated data (staff only)."""
        if not request.user.is_staff:
            return Response(
                {'detail': 'Only staff members can delete tournaments.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        tournament = get_object_or_404(Tournament, pk=pk)
        tournament.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


# ---------------------------------------------------------------------------
# Tournament — Low Net Championship
# ---------------------------------------------------------------------------

class TournamentLowNetSetupView(APIView):
    """
    GET  /api/tournaments/{id}/low-net/setup/ — return current config or defaults.
    POST /api/tournaments/{id}/low-net/setup/ — create or update championship config.

    POST body (all optional):
        handicap_mode : 'net' | 'gross' | 'strokes_off'   (default 'net')
        net_percent   : int 0-200                           (default 100)
        entry_fee     : decimal                             (default 0.00)
        payouts       : [{"place": 1, "amount": 200.00}, ...]
    """
    def get(self, request, pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        from games.models import LowNetChampionshipConfig
        from core.models import HandicapMode
        try:
            cfg = tournament.low_net_championship_config
            data = {
                'handicap_mode': cfg.handicap_mode,
                'net_percent'  : cfg.net_percent,
                'entry_fee'    : float(cfg.entry_fee),
                'payouts'      : cfg.payouts,
            }
        except LowNetChampionshipConfig.DoesNotExist:
            data = {
                'handicap_mode': HandicapMode.NET,
                'net_percent'  : 100,
                'entry_fee'    : 0.00,
                'payouts'      : [],
            }
        return Response(data)

    def post(self, request, pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        from games.models import LowNetChampionshipConfig
        d = request.data
        cfg, _ = LowNetChampionshipConfig.objects.update_or_create(
            tournament = tournament,
            defaults   = {
                'handicap_mode': d.get('handicap_mode', 'net'),
                'net_percent'  : int(d.get('net_percent', 100)),
                'entry_fee'    : d.get('entry_fee', 0.00),
                'payouts'      : d.get('payouts', []),
            },
        )
        return Response({
            'handicap_mode': cfg.handicap_mode,
            'net_percent'  : cfg.net_percent,
            'entry_fee'    : float(cfg.entry_fee),
            'payouts'      : cfg.payouts,
        }, status=status.HTTP_200_OK)


class TournamentLowNetView(APIView):
    """GET /api/tournaments/{id}/low-net/ — cumulative Low Net standings."""
    def get(self, request, pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        from services.low_net_championship import low_net_championship_summary
        return Response(low_net_championship_summary(tournament))


class TournamentLeaderboardView(APIView):
    """
    GET /api/tournaments/{id}/leaderboard/

    Returns all active tournament-level game standings in one payload.
    Supports: low_net (Low Net Championship), match_play (Match Play summary).
    Per-round game results (Irish Rumble, Pink Ball, etc.) live on the
    per-round leaderboard endpoint (/api/rounds/{id}/leaderboard/).
    """
    def get(self, request, pk):
        tournament = get_object_or_404(
            Tournament.objects.prefetch_related(
                'rounds__foursomes__memberships__player',
            ),
            pk=pk,
        )
        active_games = tournament.active_games or []
        games: dict  = {}

        # Optional round_id filter — show standings for this round only
        round_id_filter = request.query_params.get('round_id')
        round_filter = None
        if round_id_filter:
            try:
                round_filter = int(round_id_filter)
            except (ValueError, TypeError):
                pass

        if 'low_net' in active_games:
            from services.low_net_championship import low_net_championship_summary
            games['low_net'] = {
                'label'  : 'Low Net Championship',
                **low_net_championship_summary(tournament, round_id=round_filter),
            }

        if 'match_play' in active_games:
            from services.tournament_match_play import tournament_match_play_summary
            brackets = []
            for round_obj in tournament.rounds.order_by('round_number'):
                for foursome in round_obj.foursomes.order_by('group_number'):
                    try:
                        summary = tournament_match_play_summary(foursome)
                        summary['round_number'] = round_obj.round_number
                        summary['group_number'] = foursome.group_number
                        brackets.append(summary)
                    except Exception:
                        pass  # foursome has no match play bracket yet
            games['match_play'] = {
                'label'   : 'Match Play',
                'brackets': brackets,
            }

        return Response({
            'tournament_id'  : tournament.id,
            'tournament_name': tournament.name,
            'active_games'   : active_games,
            'games'          : games,
        })


class TournamentCupStandingsView(APIView):
    """
    GET /api/tournaments/{id}/cup-standings/

    Returns cumulative Ryder Cup (Nassau four-ball) points across all rounds
    in the tournament — both the running totals and a per-round breakdown.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        tournament = get_object_or_404(
            Tournament.objects.prefetch_related(
                'rounds__foursomes__memberships__player',
                'rounds__foursomes__ryder_cup_foursome_config__team1',
                'rounds__foursomes__ryder_cup_foursome_config__team2',
            ),
            pk=pk,
        )
        from services.cup_standings import cup_standings_summary
        return Response(cup_standings_summary(tournament))


# ---------------------------------------------------------------------------
# Rounds
# ---------------------------------------------------------------------------

from core.models import Course

class RoundCreateView(APIView):
    """POST /api/rounds/ — create a new round."""
    def post(self, request):
        ser = RoundCreateSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        course = get_object_or_404(Course, pk=d['course_id'])
        tournament = None
        if d.get('tournament_id'):
            tournament = get_object_or_404(Tournament, pk=d['tournament_id'])

        # Resolve the creating player from the authenticated user (may be None
        # for admin/staff accounts that have no linked Player profile).
        created_by = getattr(request.user, 'player_profile', None)

        round_obj = Round.objects.create(
            tournament        = tournament,
            round_number      = d['round_number'],
            date              = d['date'],
            course            = course,
            status            = 'pending',
            active_games      = d['active_games'],
            game_point_values = d.get('game_point_values', {}),
            cup_group_counts  = d.get('cup_group_counts', {}),
            bet_unit          = d['bet_unit'],
            handicap_mode     = d.get('handicap_mode', 'net'),
            net_percent       = d.get('net_percent', 100),
            net_max_double_bogey = d.get('net_max_double_bogey', True),
            notes             = d['notes'],
            created_by        = created_by,
        )
        return Response(RoundSerializer(round_obj).data,
                        status=status.HTTP_201_CREATED)


class RoundDetailView(APIView):
    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects
                 .select_related('course')
                 .prefetch_related(
                     'foursomes__memberships__player',
                     'foursomes__ryder_cup_foursome_config',
                 ),
            pk=pk,
        )
        return Response(RoundSerializer(round_obj).data)

    def patch(self, request, pk):
        """
        Partial update of a Round.  Currently used from the Sixes setup
        screen to let the user adjust the round-level bet_unit at the time
        they're starting a match.  RoundSerializer already exposes
        bet_unit as writable and excludes read-only fields, so we just
        delegate to it with partial=True.
        """
        round_obj = get_object_or_404(
            Round.objects
                 .select_related('course')
                 .prefetch_related(
                     'foursomes__memberships__player',
                     'foursomes__ryder_cup_foursome_config',
                 ),
            pk=pk,
        )
        ser = RoundSerializer(round_obj, data=request.data, partial=True)
        ser.is_valid(raise_exception=True)
        ser.save()
        return Response(ser.data)

    def delete(self, request, pk):
        """
        DELETE /api/rounds/{id}/ — permanently remove a casual round.
        Only the player who created the round may delete it.
        """
        round_obj = get_object_or_404(Round, pk=pk)
        requesting_player = getattr(request.user, 'player_profile', None)
        if round_obj.created_by_id is None or requesting_player is None:
            return Response(
                {'detail': 'Only the round creator can delete this round.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        if round_obj.created_by_id != requesting_player.id:
            return Response(
                {'detail': 'Only the round creator can delete this round.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        round_obj.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class CasualRoundListView(APIView):
    """
    GET /api/rounds/casual/?status=in_progress   (default)
    GET /api/rounds/casual/?status=complete

    Returns casual rounds (no tournament) that include the authenticated
    user's player in any foursome, filtered by status.  Each item contains
    enough data for the Casual Rounds list screen: date, course, active
    games, players, current hole, and whether this user is the creator
    (so the client can show the delete button).
    """
    def get(self, request):
        requesting_player = getattr(request.user, 'player_profile', None)
        if requesting_player is None:
            return Response([])

        # Accept ?status= query param; default to in_progress.
        requested_status = request.query_params.get('status', 'in_progress')
        if requested_status not in ('in_progress', 'complete', 'pending'):
            requested_status = 'in_progress'

        rounds = (
            Round.objects
            .filter(
                tournament__isnull=True,
                status=requested_status,
                foursomes__memberships__player=requesting_player,
            )
            .select_related('course', 'created_by')
            .prefetch_related(
                'foursomes__memberships__player',
            )
            .distinct()
            .order_by('-date', '-created_at')
        )

        results = []
        for r in rounds:
            # Collect all real players across all foursomes.
            players = []
            seen_ids = set()
            for fs in r.foursomes.all():
                for m in fs.memberships.all():
                    p = m.player
                    if not p.is_phantom and p.id not in seen_ids:
                        seen_ids.add(p.id)
                        players.append({
                            'id':         p.id,
                            'name':       p.name,
                            'short_name': p.display_short if hasattr(p, 'display_short') else p.name,
                        })

            # Current hole = highest hole_number where a real (non-phantom)
            # player has a gross_score.  Phantom scores are pre-filled for
            # all 18 holes at setup, so we must exclude them or every round
            # would report current_hole=18 from the start.
            from scoring.models import HoleScore as HS
            max_hole = (
                HS.objects
                .filter(
                    foursome__round=r,
                    gross_score__isnull=False,
                    player__is_phantom=False,
                )
                .order_by('-hole_number')
                .values_list('hole_number', flat=True)
                .first()
            )

            # Casual rounds have exactly one foursome.
            first_fs = r.foursomes.first()

            results.append({
                'id':                   r.id,
                'date':                 r.date,
                'course_name':          r.course.name,
                'status':               r.status,
                'active_games':         r.active_games,
                'bet_unit':             r.bet_unit,
                'current_hole':         max_hole or 0,
                'created_by_player_id': r.created_by_id,
                'foursome_id':          first_fs.id if first_fs else None,
                'players':              players,
            })

        ser = CasualRoundSummarySerializer(results, many=True)
        return Response(ser.data)


class RoundSetupView(APIView):
    """
    POST /api/rounds/{id}/setup/
    Body: {
        "players": [{"player_id": 1, "tee_id": 1}, ...],
        "handicap_allowance": 1.0,
        "randomise": true,
        "auto_setup_games": false
    }
    Draws foursomes, creates phantom scores, and optionally auto-configures
    Nassau/Sixes/MatchPlay teams by handicap rank.
    """
    @transaction.atomic
    def post(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)
        ser = RoundSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.round_setup import setup_round, create_phantom_hole_scores
        foursomes = setup_round(
            round_obj,
            players            = d['players'],
            handicap_allowance = d['handicap_allowance'],
            randomise          = d['randomise'],
        )

        # Pre-populate phantom player scores and initialise rotation config.
        from scoring.phantom import get_algorithm, DEFAULT_ALGORITHM_ID
        for fs in foursomes:
            if fs.has_phantom:
                create_phantom_hole_scores(fs)
                # Initialise phantom_config (rotation order) so services like
                # Irish Rumble that derive scores on-the-fly via PhantomScoreProvider
                # work correctly without requiring a separate frontend initPhantom call.
                phantom_m = fs.memberships.filter(player__is_phantom=True).first()
                if phantom_m and not phantom_m.phantom_config:
                    real_ms   = list(fs.memberships.filter(player__is_phantom=False))
                    real_ids  = [m.player_id for m in real_ms]
                    real_hcps = [m.playing_handicap for m in real_ms]
                    algo = get_algorithm(DEFAULT_ALGORITHM_ID)
                    phantom_m.phantom_config    = algo.initial_config(real_ids)
                    phantom_m.playing_handicap  = algo.compute_playing_handicap(
                        phantom_m.phantom_config, real_hcps
                    )
                    phantom_m.save(update_fields=['phantom_config', 'playing_handicap'])

        # Persist caller-supplied active_games before marking in_progress
        # (so _auto_setup_games reads the right game list).
        update_fields = ['status']
        if d.get('active_games'):
            round_obj.active_games = d['active_games']
            update_fields.append('active_games')

        round_obj.status = 'in_progress'
        round_obj.save(update_fields=update_fields)

        if d['auto_setup_games']:
            _auto_setup_games(round_obj, foursomes)

        round_obj = (
            Round.objects
            .select_related('course')
            .prefetch_related(
                'foursomes__memberships__player',
                'foursomes__ryder_cup_foursome_config',
            )
            .get(pk=pk)
        )
        return Response(RoundSerializer(round_obj).data, status=status.HTTP_201_CREATED)


# ---------------------------------------------------------------------------
# Foursomes
# ---------------------------------------------------------------------------

class FoursomeDetailView(APIView):
    def get(self, request, pk):
        foursome = get_object_or_404(
            Foursome.objects.prefetch_related('memberships__player'),
            pk=pk,
        )
        return Response(FoursomeSerializer(foursome).data)


class FoursomeActiveGamesView(APIView):
    """
    PATCH /api/foursomes/{id}/active-games/
    Body: { "active_games": ["irish_rumble", "pink_ball"] }

    Sets the per-foursome game override list.  Empty list means "inherit from round".
    Staff only — regular players cannot reassign games mid-round.
    """
    def patch(self, request, pk):
        if not request.user.is_staff:
            return Response(
                {'detail': 'Only staff members can configure foursome games.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        foursome = get_object_or_404(Foursome, pk=pk)
        games = request.data.get('active_games', [])
        if not isinstance(games, list):
            return Response(
                {'detail': 'active_games must be a list.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        foursome.active_games = games
        foursome.save(update_fields=['active_games'])
        return Response({
            'foursome_id' : foursome.id,
            'group_number': foursome.group_number,
            'active_games': foursome.active_games,
        })


# ---------------------------------------------------------------------------
# Scorecard
# ---------------------------------------------------------------------------

class ScorecardView(APIView):
    def get(self, request, pk):
        foursome = get_object_or_404(
            Foursome.objects
                    .select_related('round__course')
                    .prefetch_related('memberships__player'),
            pk=pk,
        )
        return Response(_build_scorecard(foursome))


# ---------------------------------------------------------------------------
# Score submission
# ---------------------------------------------------------------------------

class PhantomInitView(APIView):
    """
    POST /api/foursomes/<pk>/phantom/init/
    
    Idempotent — safe to call repeatedly.  If the phantom membership already
    has a config (non-empty phantom_config), this is a no-op and just returns
    the current source_by_hole mapping.

    Initialises the phantom player's algorithm config (e.g. the random
    rotation order) and sets their playing_handicap to the average of the
    real players' playing handicaps.

    Response:
        {
          "phantom_player_id": int,
          "playing_handicap": int,
          "algorithm": str,
          "source_by_hole": {1: player_id, 2: player_id, ...}
        }
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        if not foursome.has_phantom:
            return Response({'detail': 'This foursome has no phantom player.'},
                            status=400)

        phantom_m = foursome.memberships.filter(player__is_phantom=True).first()
        if phantom_m is None:
            return Response({'detail': 'Phantom membership not found.'}, status=404)

        real_memberships = list(foursome.memberships.filter(player__is_phantom=False))
        real_player_ids  = [m.player_id for m in real_memberships]
        real_hcaps       = [m.playing_handicap for m in real_memberships]

        algo_id   = phantom_m.phantom_algorithm or DEFAULT_ALGORITHM_ID
        algorithm = get_algorithm(algo_id)

        # Idempotent: only initialise config if not already set
        if not phantom_m.phantom_config:
            phantom_m.phantom_config = algorithm.initial_config(real_player_ids)

        # Always recalculate playing_handicap from current real players
        phantom_m.playing_handicap = algorithm.compute_playing_handicap(
            phantom_m.phantom_config, real_hcaps
        )
        phantom_m.save(update_fields=['phantom_config', 'playing_handicap'])

        source_by_hole = {
            h: algorithm.get_source_player_id(h, phantom_m.phantom_config)
            for h in range(1, 19)
        }

        return Response({
            'phantom_player_id': phantom_m.player_id,
            'playing_handicap' : phantom_m.playing_handicap,
            'algorithm'        : algo_id,
            'source_by_hole'   : source_by_hole,
        })


class ScoreSubmitView(APIView):
    """
    POST /api/foursomes/{id}/scores/

    Body:
    {
        "hole_number": 7,
        "scores": [
            {"player_id": 1, "gross_score": 5},
            {"player_id": 2, "gross_score": 4}
        ],
        "pink_ball_lost": false
    }

    Saves HoleScores, recalculates all active games, and returns
    the updated scorecard + leaderboard.
    """

    @transaction.atomic
    def post(self, request, pk):
        foursome = get_object_or_404(
            Foursome.objects
                    .select_related('round__course')
                    .prefetch_related('memberships__player'),
            pk=pk,
        )

        ser = ScoreSubmitSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        hole_number    = ser.validated_data['hole_number']
        scores         = ser.validated_data['scores']
        pink_ball_lost = ser.validated_data['pink_ball_lost']

        membership_map = {m.player_id: m for m in foursome.memberships.select_related('tee').all()}

        # Sanity check: every player must have a tee assigned, because SI (and
        # par) can differ between tees at the same course (e.g. men's vs
        # women's tees, or forward tees playing a par-4 as a par-5). Handicap
        # stroke allocation must use each player's own tee.
        missing_tee = [
            pid for pid, m in membership_map.items() if m.tee_id is None
        ]
        if missing_tee:
            return Response(
                {'detail': f'Players missing tee assignment: {missing_tee}'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        errors = [
            f"Player {s['player_id']} is not in this foursome."
            for s in scores
            if s['player_id'] not in membership_map
        ]
        if errors:
            return Response({'detail': errors}, status=status.HTTP_400_BAD_REQUEST)

        for s in scores:
            pid         = s['player_id']
            gross       = s['gross_score']
            m           = membership_map[pid]
            # Per-player SI: pulled from THIS player's tee, not a shared one.
            player_hole_info = m.tee.hole(hole_number)
            stroke_index     = player_hole_info.get('stroke_index', 18)
            hcp_strokes = m.handicap_strokes_on_hole(stroke_index)

            hs, _ = HoleScore.objects.get_or_create(
                foursome    = foursome,
                player_id   = pid,
                hole_number = hole_number,
                defaults    = {'handicap_strokes': hcp_strokes},
            )
            hs.gross_score      = gross
            hs.handicap_strokes = hcp_strokes
            hs.save()

        # Propagate scores to any cross-foursome phantom in the same round.
        # A real player's gross score may be the donor for a phantom in another
        # foursome — if so, write the phantom's HoleScore now so the Nassau
        # calculator picks it up during _recalculate_games.
        from scoring.phantom import propagate_phantom_score
        for s in scores:
            try:
                propagate_phantom_score(
                    foursome.round, hole_number, s['player_id'], s['gross_score']
                )
            except Exception:
                pass  # never block score submission due to phantom propagation

        # Pink ball lost flag
        if pink_ball_lost and 'pink_ball' in (foursome.round.active_games or []):
            from games.models import PinkBallHoleResult
            pink_order = foursome.pink_ball_order or []
            if hole_number <= len(pink_order):
                pink_pid  = pink_order[hole_number - 1]
                pink_hs   = HoleScore.objects.filter(
                    foursome=foursome, player_id=pink_pid, hole_number=hole_number
                ).first()
                pbhr, _   = PinkBallHoleResult.objects.get_or_create(
                    round       = foursome.round,
                    foursome    = foursome,
                    hole_number = hole_number,
                    defaults    = {
                        'pink_ball_player_id': pink_pid,
                        'net_score': pink_hs.net_score if pink_hs else None,
                    },
                )
                pbhr.ball_lost = True
                if pink_hs:
                    pbhr.net_score = pink_hs.net_score
                pbhr.save()

        _recalculate_games(foursome)

        round_obj  = foursome.round
        lb_games   = _build_leaderboard(round_obj)
        return Response({
            'scorecard'  : _build_scorecard(foursome),
            'leaderboard': {
                'round_id'   : round_obj.id,
                'round_date' : str(round_obj.date),
                'course'     : str(round_obj.course),
                'status'     : round_obj.status,
                'active_games': _leaderboard_active_games(round_obj, lb_games),
                'games'      : lb_games,
            },
        })


# ---------------------------------------------------------------------------
# Round completion
# ---------------------------------------------------------------------------

class RoundCompleteView(APIView):
    """
    POST /api/rounds/{id}/complete/
    Marks the round as complete and returns the final leaderboard.
    Safe to call multiple times (idempotent on status).
    """
    def post(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects
                 .select_related('course')
                 .prefetch_related('foursomes__memberships__player'),
            pk=pk,
        )
        if round_obj.status != 'complete':
            round_obj.status = 'complete'
            round_obj.save(update_fields=['status'])

        # Finalise cup points so the scoreboard reflects the completed round.
        try:
            _ = round_obj.ryder_cup_config
            from services.ryder_cup import calculate_ryder_cup_points
            calculate_ryder_cup_points(round_obj)
        except Exception:
            pass

        lb_games = _build_leaderboard(round_obj)
        return Response({
            'round_id'    : round_obj.id,
            'status'      : round_obj.status,
            'round_date'  : str(round_obj.date),
            'course'      : str(round_obj.course),
            'active_games': _leaderboard_active_games(round_obj, lb_games),
            'games'       : lb_games,
        })


class RoundReopenView(APIView):
    """
    POST /api/rounds/{id}/reopen/
    Flips a completed round back to in_progress so scores can be edited.
    Idempotent — already-open rounds are returned unchanged.
    """
    def post(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects
                 .select_related('course')
                 .prefetch_related('foursomes__memberships__player'),
            pk=pk,
        )
        if round_obj.status == 'complete':
            round_obj.status = 'in_progress'
            round_obj.save(update_fields=['status'])

        return Response({
            'round_id'  : round_obj.id,
            'status'    : round_obj.status,
            'round_date': str(round_obj.date),
            'course'    : str(round_obj.course),
        })


# ---------------------------------------------------------------------------
# Leaderboard
# ---------------------------------------------------------------------------

class LeaderboardView(APIView):
    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects.select_related('course', 'tournament').prefetch_related('foursomes'),
            pk=pk,
        )
        t          = round_obj.tournament
        lb_games   = _build_leaderboard(round_obj)
        is_cup_rnd = hasattr(round_obj, 'ryder_cup_config')
        return Response({
            'round_id'              : round_obj.id,
            'round_date'            : str(round_obj.date),
            'course'                : str(round_obj.course),
            'status'                : round_obj.status,
            'is_cup_round'          : is_cup_rnd,
            'active_games'          : _leaderboard_active_games(round_obj, lb_games),
            'tournament_id'         : t.id   if t else None,
            'tournament_name'       : t.name if t else None,
            'tournament_active_games': t.active_games or [] if t else [],
            'games'                 : lb_games,
        })


# ---------------------------------------------------------------------------
# Nassau 9-9-18
# ---------------------------------------------------------------------------

class NassauSetupView(APIView):
    """
    POST /api/foursomes/{id}/nassau/setup/
    Body: {
        "team1_player_ids": [...],
        "team2_player_ids": [...],
        "handicap_mode":   "net" | "gross" | "strokes_off",
        "net_percent":     100,
        "press_mode":      "none" | "manual" | "auto" | "both",
        "press_unit":      5.00
    }
    Creates (or replaces) the NassauGame for this foursome, then
    re-runs calculate_nassau so any pre-existing hole scores are
    reflected immediately.  Safe to call repeatedly.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        ser = NassauSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.nassau import setup_nassau, calculate_nassau, nassau_summary
        setup_nassau(
            foursome,
            team1_ids     = d['team1_player_ids'],
            team2_ids     = d['team2_player_ids'],
            handicap_mode = d.get('handicap_mode', 'net'),
            net_percent   = d.get('net_percent', 100),
            press_mode    = d.get('press_mode', 'none'),
            press_unit    = d.get('press_unit', '0.00'),
            variant       = d.get('variant', 'none'),
        )
        calculate_nassau(foursome)
        return Response(nassau_summary(foursome), status=status.HTTP_201_CREATED)


class NassauPressView(APIView):
    """
    POST /api/foursomes/{id}/nassau/press/
    Body: { "start_hole": 7 }

    Called by the losing team to declare a manual press.  The winning
    team always accepts — no pending/rejection state needed.
    Returns the updated nassau summary.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        ser = NassauPressSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.nassau import add_manual_press, nassau_summary
        try:
            add_manual_press(foursome, ser.validated_data['start_hole'])
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=status.HTTP_400_BAD_REQUEST)

        return Response(nassau_summary(foursome))


class NassauResultView(APIView):
    """GET /api/foursomes/{id}/nassau/"""
    def get(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from services.nassau import nassau_summary
        summary = nassau_summary(foursome)
        if summary is None:
            return Response(
                {'detail': 'No Nassau game set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


# ---------------------------------------------------------------------------
# Six's
# ---------------------------------------------------------------------------

class SixesSetupView(APIView):
    """
    POST /api/foursomes/{id}/sixes/setup/
    Body: { "segments": [{...}, ...] }
    See services/sixes.py for segment dict format.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        ser = SixesSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.sixes import setup_sixes
        data     = ser.validated_data
        segments = setup_sixes(
            foursome,
            data['segments'],
            handicap_mode = data.get('handicap_mode', 'net'),
            net_percent   = data.get('net_percent', 100),
        )
        return Response({'segments_created': len(segments)}, status=status.HTTP_201_CREATED)


class SixesExtraTeamsView(APIView):
    """
    POST /api/foursomes/{id}/sixes/extra-teams/
    Body: { "team1_player_ids": [pk, pk], "team2_player_ids": [pk, pk] }

    Sets teams on the existing is_extra=True segment without touching any
    standard segments or hole results.  Returns the full sixes summary.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from games.models import SixesSegment, SixesTeam
        from services.sixes import sixes_summary

        # When an extra match itself ends early, calculate_sixes spawns a
        # SECOND extra (segment_number = 5, 6, ...).  The request targets
        # the newest unconfigured extra — i.e. the one with no teams yet.
        # Using .filter(is_extra=True).first() would land on the earliest
        # extra and overwrite its teams (which then looks halved on the
        # leaderboard because the new SixesTeam rows default is_winner=False
        # while the segment's status is still 'complete' from the prior
        # calc).  So: find the highest segment_number extra whose teams
        # haven't been set.
        extras = (SixesSegment.objects
                  .filter(foursome=foursome, is_extra=True)
                  .prefetch_related('teams')
                  .order_by('-segment_number'))
        seg = next(
            (e for e in extras if e.teams.count() == 0),
            None,
        )
        if seg is None:
            return Response(
                {'error': 'No unconfigured extra segment found for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )

        t1_ids = request.data.get('team1_player_ids', [])
        t2_ids = request.data.get('team2_player_ids', [])
        if len(t1_ids) != 2 or len(t2_ids) != 2:
            return Response(
                {'error': 'Each team must have exactly 2 player IDs.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # No existing teams to replace (we deliberately picked a seg with
        # .teams.count() == 0), but .delete() is a no-op safety net in
        # case of a race where teams were created between our select
        # and this write.
        seg.teams.all().delete()

        t1 = SixesTeam.objects.create(
            segment=seg, team_number=1, team_select_method='loser_choice')
        t1.players.set(t1_ids)

        t2 = SixesTeam.objects.create(
            segment=seg, team_number=2, team_select_method='loser_choice')
        t2.players.set(t2_ids)

        # Re-run calculate_sixes AFTER the teams are saved.  Otherwise, any
        # hole scores already on file for this extra segment sit idle —
        # status stays 'pending' until another score submission triggers
        # a recalc.  Concretely: the user taps Done on hole 18 (which
        # submits the hole 18 scores and fires calculate_sixes once), THEN
        # sets the Match 5 teams.  Without this recalc, Match 5 has teams
        # but no SixesHoleResult rows, so the leaderboard shows "Pending"
        # despite every hole being scored.
        from services.sixes import calculate_sixes
        calculate_sixes(foursome)

        return Response(sixes_summary(foursome), status=status.HTTP_200_OK)


class SixesResultView(APIView):
    """GET /api/foursomes/{id}/sixes/"""
    def get(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from services.sixes import sixes_summary
        return Response(sixes_summary(foursome))


# ---------------------------------------------------------------------------
# Points 5-3-1
# ---------------------------------------------------------------------------

class Points531SetupView(APIView):
    """
    POST /api/foursomes/{id}/points_531/setup/
    Body: { "handicap_mode": "net" | "gross" | "strokes_off",
            "net_percent":  0..200 }

    Creates (or replaces) the Points531Game for this foursome, then
    re-runs calculate_points_531 so any hole scores already on file are
    reflected in the first summary the UI fetches.  Safe to call
    repeatedly — setup_points_531 and calculate_points_531 are both
    idempotent.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        ser = Points531SetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.points_531 import (
            setup_points_531, calculate_points_531, points_531_summary,
        )
        data = ser.validated_data
        setup_points_531(
            foursome,
            handicap_mode = data.get('handicap_mode', 'net'),
            net_percent   = data.get('net_percent', 100),
        )
        # Score any pre-existing hole entries right away so the first
        # UI fetch isn't blank.  calculate_points_531 is a no-op if
        # there are no scores yet.
        calculate_points_531(foursome)
        return Response(
            points_531_summary(foursome),
            status=status.HTTP_201_CREATED,
        )


class Points531ResultView(APIView):
    """GET /api/foursomes/{id}/points_531/"""
    def get(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from services.points_531 import points_531_summary
        return Response(points_531_summary(foursome))


# ---------------------------------------------------------------------------
# Skins
# ---------------------------------------------------------------------------

class SkinsSetupView(APIView):
    """
    POST /api/foursomes/{id}/skins/setup/
    Body: {
        "handicap_mode": "net" | "gross" | "strokes_off",
        "net_percent":   0..200,
        "carryover":     true | false,
        "allow_junk":    true | false
    }

    Creates (or replaces) the SkinsGame for this foursome, then
    re-runs calculate_skins so any hole scores already on file are
    reflected in the first summary the UI fetches.  Safe to call
    repeatedly.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from api.serializers import SkinsSetupSerializer
        ser = SkinsSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.skins import setup_skins, calculate_skins, skins_summary
        d = ser.validated_data
        setup_skins(
            foursome,
            handicap_mode = d.get('handicap_mode', 'net'),
            net_percent   = d.get('net_percent', 100),
            carryover     = d.get('carryover', True),
            allow_junk    = d.get('allow_junk', False),
        )
        calculate_skins(foursome)
        return Response(skins_summary(foursome), status=status.HTTP_201_CREATED)


class SkinsResultView(APIView):
    """GET /api/foursomes/{id}/skins/"""
    def get(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from services.skins import skins_summary
        return Response(skins_summary(foursome))


class SkinsJunkView(APIView):
    """
    POST /api/foursomes/{id}/skins/junk/
    Body: {
        "hole_number": 1..18,
        "junk_entries": [{"player_id": N, "junk_count": N}, ...]
    }

    Upserts SkinsPlayerHoleResult rows for the given hole.  Entries
    with junk_count=0 are deleted (so the scorer can zero out a
    mistake without leaving orphan rows).  Returns the updated summary.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from api.serializers import SkinsJunkSerializer
        ser = SkinsJunkSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from games.models import SkinsGame, SkinsPlayerHoleResult
        try:
            game = foursome.skins_game
        except SkinsGame.DoesNotExist:
            return Response(
                {'detail': 'Skins game not set up for this foursome.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        hole_number  = ser.validated_data['hole_number']
        junk_entries = ser.validated_data['junk_entries']

        for entry in junk_entries:
            pid   = entry['player_id']
            count = entry['junk_count']
            if count == 0:
                SkinsPlayerHoleResult.objects.filter(
                    game=game, player_id=pid, hole_number=hole_number
                ).delete()
            else:
                SkinsPlayerHoleResult.objects.update_or_create(
                    game=game, player_id=pid, hole_number=hole_number,
                    defaults={'junk_count': count},
                )

        from services.skins import skins_summary
        return Response(skins_summary(foursome))


# ---------------------------------------------------------------------------
# Match Play
# ---------------------------------------------------------------------------

class MatchPlayResultView(APIView):
    """GET /api/foursomes/{id}/match-play/"""
    def get(self, request, pk):
        import logging
        _log = logging.getLogger(__name__)

        foursome = get_object_or_404(Foursome, pk=pk)

        # Cup Singles — detected by RyderCupFoursomeConfig game_type.
        _cup_cfg = None
        try:
            _cup_cfg = foursome.ryder_cup_foursome_config
        except Exception:
            pass  # No cup config — fall through to standard match play

        if _cup_cfg is not None:
            from core.models import GameType as GT
            if _cup_cfg.game_type in (GT.SINGLES_NASSAU, GT.SINGLES_18):
                from services.cup_singles import (
                    cup_singles_summary, setup_cup_singles, calculate_cup_singles
                )
                summary = cup_singles_summary(foursome)
                if summary is None:
                    # Bracket not created yet — auto-create now using
                    # alternating-position fallback (team membership optional).
                    try:
                        setup_cup_singles(foursome, _cup_cfg.team1, _cup_cfg.team2,
                                          singles_matchups=[])
                        calculate_cup_singles(foursome)
                        existing  = list(foursome.active_games or [])
                        game_key  = _cup_cfg.game_type  # already the string value
                        if game_key not in existing:
                            existing.append(game_key)
                            foursome.active_games = existing
                            foursome.save(update_fields=['active_games'])
                        summary = cup_singles_summary(foursome)
                    except Exception as _e:
                        _log.error(
                            'cup singles auto-setup failed for foursome %s: %s',
                            foursome.id, _e, exc_info=True
                        )
                if summary is None:
                    return Response(
                        {'detail': 'Cup singles bracket not set up for this foursome.'},
                        status=status.HTTP_404_NOT_FOUND,
                    )
                return Response(summary)

        from services.tournament_match_play import (
            tournament_match_play_summary,
            setup_tournament_match_play,
            calculate_tournament_match_play,
        )
        summary = tournament_match_play_summary(foursome)
        if summary is None:
            return Response(
                {'detail': 'No match play bracket set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


class MatchPlaySetupView(APIView):
    """
    POST /api/foursomes/{id}/match-play/setup/

    (Re-)initialise the match play bracket for a foursome.  Players are
    seeded by playing_handicap (lowest vs highest, second vs third).
    Handicap mode is inherited from the round — no extra body params needed.

    Accepts an optional JSON body:
        { "recalculate": true }   (default true)
    If recalculate is true, an immediate calculate pass is run so the
    bracket reflects any scores already on file.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)

        # Cup foursomes with SINGLES or MATCH_PLAY game type use cup_singles setup
        try:
            cup_cfg = foursome.ryder_cup_foursome_config
            from core.models import GameType as GT
            if cup_cfg.game_type in (GT.SINGLES_NASSAU, GT.SINGLES_18):
                from services.cup_singles import (
                    setup_cup_singles,
                    calculate_cup_singles,
                    cup_singles_summary,
                )
                # Preserve explicit matchups from any existing bracket so that
                # a 1v2 (or 2v1) group keeps both matches when re-setup is called.
                existing_matchups = []
                try:
                    from games.models import MatchPlayBracket
                    existing_bracket = MatchPlayBracket.objects.filter(
                        foursome=foursome, bracket_type='cup_singles'
                    ).prefetch_related('matches__player1', 'matches__player2').first()
                    if existing_bracket:
                        existing_matchups = [
                            {'player1_id': m.player1_id, 'player2_id': m.player2_id}
                            for m in existing_bracket.matches.all()
                        ]
                except Exception:
                    pass
                try:
                    setup_cup_singles(
                        foursome, cup_cfg.team1, cup_cfg.team2,
                        singles_matchups=existing_matchups or None,
                    )
                except ValueError as exc:
                    return Response({'detail': str(exc)}, status=status.HTTP_400_BAD_REQUEST)
                game_key = cup_cfg.game_type  # 'singles_nassau' or 'singles_18'
                games = list(foursome.active_games or [])
                if game_key not in games:
                    games.append(game_key)
                    foursome.active_games = games
                    foursome.save(update_fields=['active_games'])
                recalculate = request.data.get('recalculate', True)
                if recalculate:
                    calculate_cup_singles(foursome)
                summary = cup_singles_summary(foursome)
                return Response(summary, status=status.HTTP_201_CREATED)
        except Exception:
            pass  # Not a cup foursome — fall through to regular setup

        from services.tournament_match_play import (
            setup_tournament_match_play,
            calculate_tournament_match_play,
            tournament_match_play_summary,
        )
        entry_fee     = request.data.get('entry_fee', 0.00)
        payout_config = request.data.get('payout_config', {})
        seed_order    = request.data.get('seed_order', None)   # optional list of player PKs
        try:
            setup_tournament_match_play(
                foursome,
                entry_fee=entry_fee,
                payout_config=payout_config,
                seed_order=seed_order,
            )
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=status.HTTP_400_BAD_REQUEST)

        # Ensure 'match_play' is in foursome.active_games so that
        # _recalculate_games fires calculate_tournament_match_play after every
        # score submission.
        games = list(foursome.active_games or [])
        if 'match_play' not in games:
            games.append('match_play')
            foursome.active_games = games
            foursome.save(update_fields=['active_games'])

        recalculate = request.data.get('recalculate', True)
        if recalculate:
            calculate_tournament_match_play(foursome)

        summary = tournament_match_play_summary(foursome)
        return Response(summary, status=status.HTTP_201_CREATED)


# ---------------------------------------------------------------------------
# Three-Person Match
# ---------------------------------------------------------------------------

class ThreePersonMatchResultView(APIView):
    """GET /api/foursomes/{id}/three-person-match/"""
    def get(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from services.three_person_match import three_person_match_summary
        summary = three_person_match_summary(foursome)
        if summary is None:
            return Response(
                {'detail': 'No Three-Person Match set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


class ThreePersonMatchSetupView(APIView):
    """
    POST /api/foursomes/{id}/three-person-match/setup/

    (Re-)initialise the Three-Person Match for a foursome.  Requires
    exactly 3 real players.  Accepts:
        {
            "handicap_mode": "net" | "gross" | "strokes_off",
            "net_percent":   0..200,
            "entry_fee":     float,
            "payout_config": {"1st": float, "2nd": float, "3rd": float}
        }
    Returns the full summary after an immediate calculate pass.
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        ser = ThreePersonMatchSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.three_person_match import (
            setup_three_person_match,
            calculate_three_person_match,
            three_person_match_summary,
        )
        d = ser.validated_data
        setup_three_person_match(
            foursome,
            handicap_mode = d.get('handicap_mode', 'net'),
            net_percent   = d.get('net_percent', 100),
            entry_fee     = float(d.get('entry_fee', 0.00)),
            payout_config = d.get('payout_config', {}),
        )

        # Ensure 'three_person_match' is in foursome.active_games so that
        # _recalculate_games fires calculate_three_person_match after every
        # score submission (same reason as the match_play fix above).
        games = list(foursome.active_games or [])
        if 'three_person_match' not in games:
            games.append('three_person_match')
            foursome.active_games = games
            foursome.save(update_fields=['active_games'])

        calculate_three_person_match(foursome)
        return Response(
            three_person_match_summary(foursome),
            status=status.HTTP_201_CREATED,
        )


# ---------------------------------------------------------------------------
# Irish Rumble setup (round-level)
# ---------------------------------------------------------------------------

_IR_DEFAULT_SEGMENTS = [
    {'start_hole': 1,  'end_hole': 6,  'balls_to_count': 1},
    {'start_hole': 7,  'end_hole': 12, 'balls_to_count': 2},
    {'start_hole': 13, 'end_hole': 17, 'balls_to_count': 3},
    {'start_hole': 18, 'end_hole': 18, 'balls_to_count': 4},
]


class IrishRumbleSetupView(APIView):
    """
    GET  /api/rounds/{id}/irish-rumble/setup/  — return current config or defaults
    POST /api/rounds/{id}/irish-rumble/setup/  — create or update config
    """

    def _config_dict(self, config):
        return {
            'configured'   : True,
            'handicap_mode': config.handicap_mode,
            'net_percent'  : config.net_percent,
            'entry_fee'    : float(config.entry_fee),
            'payouts'      : config.payouts or [],
            'segments'     : config.segments,
        }

    @staticmethod
    def _count_players(round_obj):
        return sum(
            1
            for fs in round_obj.foursomes.all()
            for m in fs.memberships.all()
            if not m.player.is_phantom
        )

    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects.prefetch_related('foursomes__memberships__player'),
            pk=pk,
        )
        num_players   = self._count_players(round_obj)
        is_tournament = round_obj.tournament_id is not None
        from games.models import IrishRumbleConfig
        try:
            config = round_obj.irish_rumble_config
            data   = self._config_dict(config)
        except IrishRumbleConfig.DoesNotExist:
            data = {
                'configured'   : False,
                'handicap_mode': round_obj.handicap_mode,
                'net_percent'  : round_obj.net_percent,
                'entry_fee'    : 0.00,
                'payouts'      : [],
                'segments'     : _IR_DEFAULT_SEGMENTS,
            }
        data['num_players']          = num_players
        data['is_tournament_round']  = is_tournament
        data['round_handicap_mode']  = round_obj.handicap_mode
        data['round_net_percent']    = round_obj.net_percent
        return Response(data)

    def post(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)
        ser = IrishRumbleSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        # For tournament rounds, the handicap mode is set at the round level
        # and cannot be overridden per-game.
        if round_obj.tournament_id:
            hcap_mode   = round_obj.handicap_mode
            net_pct     = round_obj.net_percent
        else:
            hcap_mode   = d['handicap_mode']
            net_pct     = d['net_percent']

        from games.models import IrishRumbleConfig
        config, _ = IrishRumbleConfig.objects.update_or_create(
            round    = round_obj,
            defaults = {
                'handicap_mode': hcap_mode,
                'net_percent'  : net_pct,
                'entry_fee'    : d['entry_fee'],
                'payouts'      : d['payouts'],
                'segments'     : _IR_DEFAULT_SEGMENTS,
            },
        )
        # Recalculate if there are already hole scores on file
        from services.irish_rumble import calculate_irish_rumble
        try:
            calculate_irish_rumble(round_obj)
        except Exception:
            pass  # No scores yet — calculation will run after first score save

        return Response(self._config_dict(config), status=status.HTTP_201_CREATED)


# ---------------------------------------------------------------------------
# Low Net setup (round-level)
# ---------------------------------------------------------------------------

class LowNetSetupView(APIView):
    """
    GET  /api/rounds/{id}/low-net/setup/  — return current config or defaults
    POST /api/rounds/{id}/low-net/setup/  — create or update config
    """

    def _config_dict(self, config):
        return {
            'configured'         : True,
            'handicap_mode'      : config.handicap_mode,
            'net_percent'        : config.net_percent,
            'entry_fee'          : float(config.entry_fee),
            'payouts'            : config.payouts or [],
            'excluded_player_ids': config.excluded_player_ids or [],
        }

    @staticmethod
    def _count_players(round_obj):
        """Count real (non-phantom) players across all foursomes in the round."""
        return sum(
            1
            for fs in round_obj.foursomes.all()
            for m in fs.memberships.all()
            if not m.player.is_phantom
        )

    @staticmethod
    def _championship_placers(round_obj):
        """
        Return players who won prize money in the tournament's Low Net
        Championship standings, suggested for exclusion from day-2 prizes.
        Only called when the round belongs to a tournament.
        """
        if not round_obj.tournament_id:
            return []
        try:
            from services.low_net_championship import low_net_championship_standings
            # Need the tournament object with the right prefetch
            from tournament.models import Tournament
            tournament = Tournament.objects.prefetch_related(
                'rounds__foursomes__memberships__player'
            ).get(pk=round_obj.tournament_id)
            standings = low_net_championship_standings(tournament)
            return [
                {
                    'player_id'  : s['player_id'],
                    'player_name': s['player_name'],
                    'rank'       : s['rank'],
                    'payout'     : s['payout'],
                }
                for s in standings
                if s['payout'] is not None
            ]
        except Exception:
            return []

    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects
                 .select_related('tournament')
                 .prefetch_related('foursomes__memberships__player'),
            pk=pk,
        )
        num_players   = self._count_players(round_obj)
        is_tournament = round_obj.tournament_id is not None
        from games.models import LowNetRoundConfig
        try:
            config = round_obj.low_net_config
            data   = {'num_players': num_players, **self._config_dict(config)}
        except LowNetRoundConfig.DoesNotExist:
            data = {
                'num_players'        : num_players,
                'configured'         : False,
                'handicap_mode'      : round_obj.handicap_mode,
                'net_percent'        : round_obj.net_percent,
                'entry_fee'          : 0.00,
                'payouts'            : [],
                'excluded_player_ids': [],
            }
        data['is_tournament_round']  = is_tournament
        data['round_handicap_mode']  = round_obj.handicap_mode
        data['round_net_percent']    = round_obj.net_percent
        data['championship_placers'] = self._championship_placers(round_obj)
        return Response(data)

    def post(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)
        ser = LowNetSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        if round_obj.tournament_id:
            hcap_mode = round_obj.handicap_mode
            net_pct   = round_obj.net_percent
        else:
            hcap_mode = d['handicap_mode']
            net_pct   = d['net_percent']

        from games.models import LowNetRoundConfig
        config, _ = LowNetRoundConfig.objects.update_or_create(
            round    = round_obj,
            defaults = {
                'handicap_mode'      : hcap_mode,
                'net_percent'        : net_pct,
                'entry_fee'          : d['entry_fee'],
                'payouts'            : d['payouts'],
                'excluded_player_ids': d.get('excluded_player_ids', []),
            },
        )
        return Response(self._config_dict(config), status=status.HTTP_201_CREATED)


# ---------------------------------------------------------------------------
# Pink Ball setup (round-level) + per-foursome order
# ---------------------------------------------------------------------------

class PinkBallSetupView(APIView):
    """
    GET  /api/rounds/{id}/pink-ball/setup/
        Returns current config (ball_color, entry_fee, payouts) plus each
        foursome's current pink_ball_order and player list.

    POST /api/rounds/{id}/pink-ball/setup/
        Save ball_color, entry_fee, and payouts.
    """

    @staticmethod
    def _foursome_data(fs):
        real_members = (
            fs.memberships.filter(player__is_phantom=False)
                          .select_related('player')
                          .order_by('id')
        )
        from games.models import PinkBallResult
        result = PinkBallResult.objects.filter(round=fs.round, foursome=fs).first()
        return {
            'foursome_id'      : fs.pk,
            'group_number'     : fs.group_number,
            'players'          : [
                {'id': m.player.pk, 'name': m.player.name,
                 'short_name': m.player.short_name}
                for m in real_members
            ],
            'order'            : fs.pink_ball_order or [],
            'eliminated_on_hole': result.eliminated_on_hole if result else None,
        }

    @staticmethod
    def _count_players(round_obj):
        return sum(
            1
            for fs in round_obj.foursomes.all()
            for m in fs.memberships.all()
            if not m.player.is_phantom
        )

    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects.prefetch_related('foursomes__memberships__player'),
            pk=pk,
        )
        num_players = self._count_players(round_obj)
        from games.models import PinkBallConfig
        try:
            config      = round_obj.pink_ball_config
            configured  = True
            ball_color  = config.ball_color
            entry_fee   = float(config.entry_fee)
            payouts     = config.payouts or []
        except PinkBallConfig.DoesNotExist:
            configured  = False
            ball_color  = 'Pink'
            entry_fee   = 0.00
            payouts     = []

        foursomes_data = [
            self._foursome_data(fs)
            for fs in round_obj.foursomes.order_by('group_number')
        ]
        return Response({
            'configured' : configured,
            'ball_color' : ball_color,
            'entry_fee'  : entry_fee,
            'payouts'    : payouts,
            'num_players': num_players,
            'foursomes'  : foursomes_data,
        })

    def post(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)
        from api.serializers import PinkBallSetupSerializer
        ser = PinkBallSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data
        from games.models import PinkBallConfig
        config, _ = PinkBallConfig.objects.update_or_create(
            round    = round_obj,
            defaults = {
                'ball_color': d['ball_color'],
                'entry_fee' : d['entry_fee'],
                'payouts'   : d['payouts'],
            },
        )
        return Response({
            'configured': True,
            'ball_color': config.ball_color,
            'entry_fee' : float(config.entry_fee),
            'payouts'   : config.payouts or [],
        }, status=status.HTTP_201_CREATED)


# ---------------------------------------------------------------------------
# Course import from GolfCourseAPI (golfcourseapi.com)
# ---------------------------------------------------------------------------

class GolfApiSearchView(APIView):
    """
    GET /api/courses/golf-api/search/?q={query}

    Proxies a course-name search to GolfCourseAPI and annotates each result
    with whether the course already exists in the local database.
    Staff only — regular players don't manage the course library.
    """
    def get(self, request):
        if not request.user.is_staff:
            return Response(
                {'detail': 'Only staff members can search for courses.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        query = request.query_params.get('q', '').strip()
        if len(query) < 2:
            return Response(
                {'detail': 'Please enter at least 2 characters to search.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        from services.golf_api_client import search_courses
        try:
            courses = search_courses(query)
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
        except Exception as exc:
            import traceback, logging
            logging.getLogger(__name__).error('GolfCourseAPI search error:\n%s', traceback.format_exc())
            return Response(
                {'detail': str(exc)},
                status=status.HTTP_502_BAD_GATEWAY,
            )

        # Annotate with local DB existence.
        # Match on the canonical course name we'd assign on import.
        from core.models import Course as CourseModel
        existing_names = set(CourseModel.objects.values_list('name', flat=True))
        for c in courses:
            c['already_imported'] = _course_display_name(c) in existing_names

        return Response({'courses': courses})


class GolfApiCourseDetailView(APIView):
    """
    GET /api/courses/golf-api/courses/{course_id}/

    Fetches a single course from GolfCourseAPI (tees + holes) and annotates
    with local-DB existence.  Used by the mobile app to preview tee sets
    before committing to an import.
    """
    def get(self, request, course_id):
        if not request.user.is_staff:
            return Response(
                {'detail': 'Only staff members can fetch course details.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        from services.golf_api_client import fetch_course
        try:
            course = fetch_course(course_id)
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
        except Exception as exc:
            import traceback, logging
            logging.getLogger(__name__).error('GolfCourseAPI detail error:\n%s', traceback.format_exc())
            return Response(
                {'detail': f'Golf API error: {exc}'},
                status=status.HTTP_502_BAD_GATEWAY,
            )

        from core.models import Course as CourseModel
        existing_names = set(CourseModel.objects.values_list('name', flat=True))
        course['already_imported'] = _course_display_name(course) in existing_names

        return Response(course)


def _course_display_name(api_course: dict) -> str:
    """
    Build the canonical name we store locally for a course returned by
    GolfCourseAPI.  If club_name and course_name differ (the club has
    multiple courses), we disambiguate; otherwise we use club_name alone.
    """
    club   = (api_course.get('club_name')   or '').strip()
    course = (api_course.get('course_name') or '').strip()
    if course and course != club:
        return f'{club} — {course}'
    return club


class CourseImportView(APIView):
    """
    POST /api/courses/import/
    Body:
        {
            "course_id"   : 99,      # GolfCourseAPI numeric course ID (required)
            "force_update": false    # True = overwrite tees if course already exists
        }

    Fetches the full course from GolfCourseAPI, creates (or updates) the
    local Course and Tee records, and returns the saved Course with its tees.

    Already-exists behaviour
    ~~~~~~~~~~~~~~~~~~~~~~~~
    * force_update = false (default): returns HTTP 409 with the existing
      course data so the mobile can offer the user a Skip/Update choice.
    * force_update = true: deletes all existing Tee rows for the course and
      re-creates them from the API data.  The Course row itself is preserved
      (rounds referencing it stay intact).
    """
    @transaction.atomic
    def post(self, request):
        if not request.user.is_staff:
            return Response(
                {'detail': 'Only staff members can import courses.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        course_id    = request.data.get('course_id')
        force_update = bool(request.data.get('force_update', False))

        if not course_id:
            return Response(
                {'detail': 'course_id is required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        from services.golf_api_client import fetch_course
        try:
            api_course = fetch_course(course_id)
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
        except Exception as exc:
            return Response(
                {'detail': f'Golf API error: {exc}'},
                status=status.HTTP_502_BAD_GATEWAY,
            )

        course_name = _course_display_name(api_course)
        if not course_name:
            return Response(
                {'detail': 'API returned a course with no name.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        from core.models import Course as CourseModel, Tee as TeeModel
        from .serializers import CourseSerializer

        existing = CourseModel.objects.filter(name=course_name).first()

        if existing and not force_update:
            return Response(
                {
                    'already_exists': True,
                    'course'        : CourseSerializer(existing).data,
                },
                status=status.HTTP_409_CONFLICT,
            )

        # ── Create or reuse the Course row ────────────────────────────────────
        if existing:
            course_obj = existing
            TeeModel.objects.filter(course=course_obj).delete()
        else:
            course_obj = CourseModel.objects.create(name=course_name)

        # ── Create Tee rows ───────────────────────────────────────────────────
        import logging as _logging
        _log = _logging.getLogger(__name__)

        tees = api_course.get('tees', [])
        _log.info(
            'CourseImportView: course_id=%s name=%r tee_count=%d',
            course_id, course_name, len(tees),
        )

        incomplete_tees = []
        for priority, tee_data in enumerate(tees, start=10):
            holes = tee_data.get('holes', [])
            if len(holes) != 18:
                # Log but continue — slope/rating/par are still usable for
                # handicap differential calculation even without per-hole data.
                _log.warning(
                    'Tee "%s" has %d holes (expected 18); importing anyway.',
                    tee_data.get('name', '?'), len(holes),
                )
                incomplete_tees.append(tee_data.get('name', '?'))

            TeeModel.objects.create(
                course        = course_obj,
                tee_name      = tee_data['name'] or 'Default',
                slope         = max(55, min(155, tee_data['slope'])),
                course_rating = tee_data['course_rating'],
                par           = tee_data['par'],
                sex           = tee_data['sex'],
                sort_priority = priority,
                holes         = [
                    {
                        'number'      : h['number'],
                        'par'         : h['par'],
                        'stroke_index': h['stroke_index'],
                        'yards'       : h['yards'],
                    }
                    for h in holes  # ordered 1..N from the adapter
                ],
            )

        tee_count = TeeModel.objects.filter(course=course_obj).count()
        result = {
            'already_exists' : existing is not None,
            'created'        : existing is None,
            'tees_imported'  : tee_count,
            'course'         : CourseSerializer(course_obj).data,
        }
        if incomplete_tees:
            result['warning'] = (
                f'The following tees were imported without full hole data '
                f'(slope/rating/par are correct, but per-hole handicap '
                f'allocation will be unavailable): {", ".join(incomplete_tees)}'
            )
        return Response(result, status=status.HTTP_201_CREATED)


class PinkBallFoursomeOrderView(APIView):
    """
    POST /api/foursomes/{id}/pink-ball/order/
        Body: {"order": [player_pk, ...]}  (exactly 18 entries)
        Saves the custom rotation for this foursome.
    """

    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from api.serializers import PinkBallOrderSerializer
        ser = PinkBallOrderSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        order = ser.validated_data['order']

        # Validate: all PKs must be real players in this foursome
        real_ids = set(
            foursome.memberships.filter(player__is_phantom=False)
                                .values_list('player_id', flat=True)
        )
        for pid in order:
            if pid not in real_ids:
                from rest_framework.exceptions import ValidationError as DRFValidationError
                raise DRFValidationError(
                    f'Player {pid} is not a real member of this foursome.'
                )

        foursome.pink_ball_order = order
        foursome.save(update_fields=['pink_ball_order'])
        return Response({'order': order})


# ---------------------------------------------------------------------------
# Version check — called by the mobile app on startup to verify compatibility
# GET /api/version/   (no authentication required)
# ---------------------------------------------------------------------------

class VersionCheckView(APIView):
    """
    Returns the server version and the minimum client version that this server
    is willing to talk to.

    Response:
        {
          "server_version":    "1.1.0",
          "min_client_version": "1.1.0"
        }

    The Flutter app compares its own hardcoded version against
    min_client_version.  If the client is older, it shows a blocking
    "please update" dialog.  Raise CLIENT_MIN_VERSION in settings.py
    whenever a server change breaks older clients.
    """
    permission_classes = []   # public — no token required
    authentication_classes = []

    def get(self, request):
        from django.conf import settings as django_settings
        return Response({
            'server_version':     getattr(django_settings, 'SERVER_VERSION',     '1.0.0'),
            'min_client_version': getattr(django_settings, 'CLIENT_MIN_VERSION', '1.0.0'),
        })


# ---------------------------------------------------------------------------
# Health check — used by Railway to confirm the app is running
# ---------------------------------------------------------------------------

def health_check(request):
    return JsonResponse({'status': 'ok'})


# ---------------------------------------------------------------------------
# Debug / admin helper — list singles_18 matches
# GET /api/debug/singles-matches/?player=ryan
# GET /api/debug/singles-matches/?round=6
# Lists every cup_singles bracket with player names, IDs, handicaps, and
# per-match stroke differentials.  Read-only, no auth required.
# ---------------------------------------------------------------------------
def debug_singles_matches(request):
    from games.models import MatchPlayBracket
    from tournament.models import Foursome, FoursomeMembership

    player_q     = (request.GET.get('player') or '').strip().lower()
    round_number = request.GET.get('round')

    # All foursomes with a cup_singles bracket or singles_18 in active_games
    bracket_fs_ids = set(
        MatchPlayBracket.objects
        .filter(bracket_type='cup_singles')
        .values_list('foursome_id', flat=True)
    )
    singles_fs_ids = set(
        Foursome.objects
        .filter(active_games__contains=['singles_18'])
        .values_list('id', flat=True)
    )
    all_ids = bracket_fs_ids | singles_fs_ids

    qs = Foursome.objects.filter(pk__in=all_ids).select_related(
        'round__tournament'
    ).order_by('round__round_number', 'group_number')

    if round_number:
        qs = qs.filter(round__round_number=round_number)

    if player_q:
        matching_fs = FoursomeMembership.objects.filter(
            player__name__icontains=player_q,
            player__is_phantom=False,
        ).values_list('foursome_id', flat=True)
        qs = qs.filter(pk__in=matching_fs)

    results = []
    for fs in qs:
        members = list(
            FoursomeMembership.objects
            .filter(foursome=fs, player__is_phantom=False)
            .select_related('player')
        )

        try:
            bracket = (
                MatchPlayBracket.objects
                .prefetch_related(
                    'matches__player1',
                    'matches__player2',
                    'matches__hole_results',
                )
                .get(foursome=fs, bracket_type='cup_singles')
            )
            matches_out = []
            player_ids_in_matches = set()
            for m in bracket.matches.all():
                player_ids_in_matches.add(m.player1_id)
                player_ids_in_matches.add(m.player2_id)
                hcp1 = next(
                    (mb.playing_handicap for mb in members if mb.player_id == m.player1_id), None
                )
                hcp2 = next(
                    (mb.playing_handicap for mb in members if mb.player_id == m.player2_id), None
                )
                diff_p1 = max(0, (hcp1 or 0) - (hcp2 or 0))
                diff_p2 = max(0, (hcp2 or 0) - (hcp1 or 0))
                matches_out.append({
                    'match_id'        : m.id,
                    'player1'         : m.player1.name,
                    'player1_id'      : m.player1_id,
                    'player1_hcp'     : hcp1,
                    'player1_strokes' : diff_p1,
                    'player2'         : m.player2.name,
                    'player2_id'      : m.player2_id,
                    'player2_hcp'     : hcp2,
                    'player2_strokes' : diff_p2,
                    'holes_played'    : m.hole_results.count(),
                    'result'          : m.result,
                    'status'          : m.status,
                })

            missing = [
                {'name': mb.player.name, 'id': mb.player_id}
                for mb in members
                if mb.player_id not in player_ids_in_matches
            ]
            bracket_info = {
                'bracket_id'    : bracket.id,
                'bracket_status': bracket.status,
                'match_count'   : len(matches_out),
                'matches'       : matches_out,
                'players_missing_from_matches': missing,
                'warning'       : (
                    'One or more players have no match — likely a 1v2 setup bug'
                    if missing else None
                ),
            }
        except MatchPlayBracket.DoesNotExist:
            bracket_info = {'bracket_id': None, 'warning': 'No cup_singles bracket'}

        results.append({
            'foursome_id'  : fs.id,
            'group_number' : fs.group_number,
            'round_number' : fs.round.round_number if fs.round else None,
            'round_id'     : fs.round_id,
            'tournament'   : fs.round.tournament.name if (fs.round and fs.round.tournament) else None,
            'active_games' : fs.active_games,
            'players'      : [
                {'name': mb.player.name, 'id': mb.player_id, 'hcp': mb.playing_handicap}
                for mb in members
            ],
            'bracket'      : bracket_info,
        })

    return JsonResponse({'count': len(results), 'foursomes': results}, json_dumps_params={'indent': 2})


# ---------------------------------------------------------------------------
# POST /api/debug/singles-matches/<foursome_id>/fix/
# Body: {"pairs": [[player1_id, player2_id], ...]}
# Re-creates the cup_singles bracket with the given pairings and recalculates.
# ---------------------------------------------------------------------------
@csrf_exempt
def debug_fix_singles_match(request, foursome_id):
    import json
    from django.db import transaction
    from tournament.models import Foursome

    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=405)

    try:
        foursome = Foursome.objects.select_related('round').get(pk=foursome_id)
    except Foursome.DoesNotExist:
        return JsonResponse({'error': f'No foursome with id={foursome_id}'}, status=404)

    try:
        body = json.loads(request.body)
        raw_pairs = body.get('pairs', [])
    except (json.JSONDecodeError, AttributeError):
        return JsonResponse({'error': 'Invalid JSON body'}, status=400)

    if not raw_pairs:
        return JsonResponse({'error': '"pairs" list is required, e.g. [[10,5],[9,5]]'}, status=400)

    singles_matchups = [
        {'player1_id': int(p[0]), 'player2_id': int(p[1])}
        for p in raw_pairs
    ]

    try:
        with transaction.atomic():
            from services.cup_singles import setup_cup_singles, calculate_cup_singles
            from games.models import MatchPlayBracket

            setup_cup_singles(foursome, None, None, singles_matchups=singles_matchups)
            calculate_cup_singles(foursome)

            bracket = (
                MatchPlayBracket.objects
                .prefetch_related('matches__player1', 'matches__player2', 'matches__hole_results')
                .get(foursome=foursome, bracket_type='cup_singles')
            )

            from tournament.models import FoursomeMembership
            members = {
                m.player_id: m.playing_handicap
                for m in FoursomeMembership.objects.filter(
                    foursome=foursome, player__is_phantom=False
                )
            }

            matches_out = []
            for m in bracket.matches.all():
                hcp1 = members.get(m.player1_id, 0)
                hcp2 = members.get(m.player2_id, 0)
                matches_out.append({
                    'match_id'        : m.id,
                    'player1'         : m.player1.name,
                    'player1_id'      : m.player1_id,
                    'player1_hcp'     : hcp1,
                    'player1_strokes' : max(0, hcp1 - hcp2),
                    'player2'         : m.player2.name,
                    'player2_id'      : m.player2_id,
                    'player2_hcp'     : hcp2,
                    'player2_strokes' : max(0, hcp2 - hcp1),
                    'holes_played'    : m.hole_results.count(),
                    'result'          : m.result,
                    'status'          : m.status,
                })

            # Refresh Ryder Cup standings
            cup_updated = False
            try:
                from services.ryder_cup import calculate_ryder_cup_points
                calculate_ryder_cup_points(foursome.round)
                cup_updated = True
            except Exception:
                pass

            return JsonResponse({
                'ok'                  : True,
                'foursome_id'         : foursome_id,
                'bracket_id'          : bracket.id,
                'bracket_status'      : bracket.status,
                'matches'             : matches_out,
                'cup_standings_updated': cup_updated,
            }, json_dumps_params={'indent': 2})

    except Exception as exc:
        return JsonResponse({'error': str(exc)}, status=500)


# ===========================================================================
# TEAM TOURNAMENT  (Ryder Cup / Presidents Cup / custom cup name)
# ===========================================================================
#
# Endpoint map
# ~~~~~~~~~~~~
# POST  /api/tournaments/<pk>/team-tournament/setup/
#       Create (or replace) the TeamTournament and its team stubs.
#
# GET   /api/tournaments/<pk>/team-tournament/
#       Return current standings + roster.
#
# POST  /api/tournaments/<pk>/team-tournament/teams/<team_pk>/players/
#       Add a player to a team (draft pick).
#
# DELETE /api/tournaments/<pk>/team-tournament/teams/<team_pk>/players/<player_pk>/
#       Remove a player from a team.
#
# POST  /api/tournaments/<pk>/team-tournament/draft-complete/
#       Lock rosters.
#
# POST  /api/rounds/<pk>/ryder-cup/setup/
#       Configure Ryder Cup scoring for one round (game types, pairings, points).
#
# GET   /api/rounds/<pk>/ryder-cup/
#       Return per-round Ryder Cup points and match breakdown.
#
# POST  /api/rounds/<pk>/ryder-cup/calculate/
#       Recalculate all Ryder Cup points for a round from current game results.
#
# POST  /api/foursomes/<pk>/quota-nassau/setup/
#       Create/replace the Quota Nassau game for this foursome.
#
# GET   /api/foursomes/<pk>/quota-nassau/
#       Return the Quota Nassau summary (hole-by-hole + segment results).
# ===========================================================================

from tournament.models import (
    TeamTournament, TournamentTeam,
    RyderCupRoundConfig, RyderCupFoursomeConfig,
    RyderCupIrishRumblePairing,
)
from services.ryder_cup import calculate_ryder_cup_points, ryder_cup_summary
from services.quota_nassau import (
    setup_quota_nassau, calculate_quota_nassau, quota_nassau_summary,
)
from .serializers import (
    TeamTournamentSetupSerializer, TeamPlayerSerializer,
    RyderCupRoundSetupSerializer, QuotaNassauSetupSerializer,
)


# ---------------------------------------------------------------------------
# Helper: auto-calculate quota (36 - course_handicap_index) from membership
# ---------------------------------------------------------------------------

def _quota_for_player(foursome, player_id: int) -> int:
    """
    Quota = 36 − course_handicap_index (rounded integer).
    Reads course_handicap from the stored FoursomeMembership so it's
    consistent with how handicaps were calculated at round setup time.
    """
    try:
        m = foursome.memberships.get(player_id=player_id)
        return max(0, 36 - m.course_handicap)
    except Exception:
        return 18   # sensible fallback if membership not found


# ---------------------------------------------------------------------------
# Team Tournament setup
# ---------------------------------------------------------------------------

class TeamTournamentSetupView(APIView):
    """
    POST /api/tournaments/<pk>/team-tournament/setup/

    Creates a TeamTournament for an existing Tournament (or replaces it
    if one already exists).  Accepts cup_name so the competition can be
    named anything — 'Ryder Cup', 'Bandon Cup 2026', etc.

    Deleting the existing TeamTournament cascades to TournamentTeam rows,
    so all previous rosters are cleared.  Call before the draft begins.
    """
    permission_classes = [IsAuthenticated]

    @transaction.atomic
    def post(self, request, pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        ser = TeamTournamentSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        # Replace any existing TeamTournament for this tournament
        TeamTournament.objects.filter(tournament=tournament).delete()

        tt = TeamTournament.objects.create(
            tournament       = tournament,
            cup_name         = d['cup_name'],
            players_per_team = d['players_per_team'],
            draft_complete   = False,
        )
        for team_data in d['teams']:
            TournamentTeam.objects.create(
                tournament  = tt,
                team_number = team_data['team_number'],
                name        = team_data['name'],
                colour      = team_data.get('colour', ''),
                short_code  = team_data.get('short_code', ''),
            )

        return Response(
            _team_tournament_detail(tt),
            status=status.HTTP_201_CREATED,
        )


class TeamTournamentDetailView(APIView):
    """
    GET /api/tournaments/<pk>/team-tournament/

    Returns the current standings (ryder_cup_summary) and team rosters.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        tt = get_object_or_404(TeamTournament, tournament=tournament)
        return Response(ryder_cup_summary(tt))


class TeamTournamentDraftCompleteView(APIView):
    """
    POST /api/tournaments/<pk>/team-tournament/draft-complete/

    Locks team rosters.  Once draft_complete=True the UI should prevent
    further player moves.  No body required.
    """
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        tt = get_object_or_404(TeamTournament, tournament=tournament)
        tt.draft_complete = True
        tt.save(update_fields=['draft_complete'])
        return Response({'draft_complete': True, 'cup_name': tt.cup_name})


class TeamPlayerView(APIView):
    """
    POST   /api/tournaments/<pk>/team-tournament/teams/<team_pk>/players/
        Add player_id to this team's roster.
        Body: {"player_id": 5}

    DELETE /api/tournaments/<pk>/team-tournament/teams/<team_pk>/players/<player_pk>/
        Remove player from this team's roster.
    """
    permission_classes = [IsAuthenticated]

    def post(self, request, pk, team_pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        tt         = get_object_or_404(TeamTournament, tournament=tournament)
        team       = get_object_or_404(TournamentTeam, pk=team_pk, tournament=tt)

        if tt.draft_complete:
            return Response(
                {'detail': 'Draft is complete. Rosters are locked.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        ser = TeamPlayerSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        player_id = ser.validated_data['player_id']
        player    = get_object_or_404(Player, pk=player_id)

        # Remove player from any other team in this tournament first
        for other_team in tt.teams.exclude(pk=team.pk):
            other_team.players.remove(player)

        team.players.add(player)
        return Response(_team_roster(team))

    def delete(self, request, pk, team_pk, player_pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        tt         = get_object_or_404(TeamTournament, tournament=tournament)
        team       = get_object_or_404(TournamentTeam, pk=team_pk, tournament=tt)

        if tt.draft_complete:
            return Response(
                {'detail': 'Draft is complete. Rosters are locked.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        player = get_object_or_404(Player, pk=player_pk)
        team.players.remove(player)
        return Response(_team_roster(team))


class TeamRenameView(APIView):
    """
    PATCH /api/tournaments/<pk>/team-tournament/teams/<team_pk>/
        Rename a team.
        Body: {"name": "Blue Team"}
    """
    permission_classes = [IsAuthenticated]

    def patch(self, request, pk, team_pk):
        tournament = get_object_or_404(Tournament, pk=pk)
        tt         = get_object_or_404(TeamTournament, tournament=tournament)
        team       = get_object_or_404(TournamentTeam, pk=team_pk, tournament=tt)

        name = request.data.get('name', '').strip()
        if not name:
            return Response(
                {'detail': 'Team name cannot be empty.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        team.name = name
        team.save(update_fields=['name'])
        return Response({'id': team.pk, 'name': team.name})


# ---------------------------------------------------------------------------
# Ryder Cup round config
# ---------------------------------------------------------------------------

class RyderCupRoundSetupView(APIView):
    """
    POST /api/rounds/<pk>/ryder-cup/setup/

    Configure Ryder Cup scoring for a round.  Creates:
      - RyderCupRoundConfig (point value, multiplier, notes)
      - RyderCupFoursomeConfig for every foursome listed in `foursomes`
      - RyderCupIrishRumblePairing for every entry in `irish_rumble_pairings`

    Replaces any existing config for this round.
    The round must already belong to a Tournament that has a TeamTournament.
    """
    permission_classes = [IsAuthenticated]

    @transaction.atomic
    def post(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)

        if not round_obj.tournament_id:
            return Response(
                {'detail': 'This round is not linked to a tournament.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            tt = round_obj.tournament.team_tournament
        except TeamTournament.DoesNotExist:
            return Response(
                {'detail': 'This tournament does not have a team competition set up yet.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        ser = RyderCupRoundSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        # Replace existing config (cascades to foursome configs + pairings)
        RyderCupRoundConfig.objects.filter(round=round_obj).delete()

        rc = RyderCupRoundConfig.objects.create(
            round              = round_obj,
            tournament         = tt,
            nassau_point_value = d['nassau_point_value'],
            point_multiplier   = d['point_multiplier'],
            notes              = d['notes'],
        )

        # Per-foursome configs
        # Collect phantom foursomes to configure after all Nassau games are set up
        # (donors from other foursomes need their memberships to exist first).
        _phantom_foursomes_to_configure: list = []

        for fs_data in d.get('foursomes', []):
            foursome = get_object_or_404(Foursome, pk=fs_data['foursome_id'])
            team1 = get_object_or_404(TournamentTeam, pk=fs_data['team1_id'], tournament=tt) if fs_data.get('team1_id') else None
            team2 = get_object_or_404(TournamentTeam, pk=fs_data['team2_id'], tournament=tt) if fs_data.get('team2_id') else None
            RyderCupFoursomeConfig.objects.create(
                foursome     = foursome,
                round_config = rc,
                game_type    = fs_data['game_type'],
                team1        = team1,
                team2        = team2,
                point_value  = fs_data.get('point_value', '1.00'),
            )

            # Auto-setup Nassau game for cup nassau foursomes
            if fs_data['game_type'] == GameType.NASSAU:
                from services.nassau import setup_nassau
                foursome_player_ids = set(
                    foursome.memberships.filter(player__is_phantom=False)
                    .values_list('player_id', flat=True)
                )
                t1_ids = [p.pk for p in team1.players.all() if p.pk in foursome_player_ids] if team1 else []
                t2_ids = [p.pk for p in team2.players.all() if p.pk in foursome_player_ids] if team2 else []

                # Detect which team's real players are under-represented —
                # that team has the phantom. Include the phantom in the Nassau
                # team (it participates in best-ball via cross-foursome scores).
                if foursome.has_phantom:
                    real_pids = set(foursome.memberships.filter(
                        player__is_phantom=False
                    ).values_list('player_id', flat=True))
                    t1_all_pids = set(team1.players.values_list('id', flat=True)) if team1 else set()
                    t2_all_pids = set(team2.players.values_list('id', flat=True)) if team2 else set()
                    phantom_pid = foursome.memberships.filter(
                        player__is_phantom=True
                    ).values_list('player_id', flat=True).first()
                    if phantom_pid:
                        t1_real_count = len(real_pids & t1_all_pids)
                        t2_real_count = len(real_pids & t2_all_pids)
                        # Phantom fills the under-represented team
                        if t1_real_count < t2_real_count:
                            t1_ids = t1_ids + [phantom_pid]
                            phantom_team = team1
                        else:
                            t2_ids = t2_ids + [phantom_pid]
                            phantom_team = team2
                    else:
                        phantom_team = None
                else:
                    phantom_team = None

                # Delete any existing Nassau game for this foursome to avoid duplicates
                from games.models import NassauGame
                NassauGame.objects.filter(foursome=foursome).delete()
                setup_nassau(
                    foursome,
                    t1_ids,
                    t2_ids,
                    handicap_mode=round_obj.handicap_mode,
                    net_percent=round_obj.net_percent,
                )

                # If this foursome has a Four Ball phantom, configure the
                # cross-foursome rotation after ALL foursome configs have
                # been created (deferred to after loop). Store for later.
                print(f'[nassau setup] foursome={foursome.id} has_phantom={foursome.has_phantom} phantom_team={phantom_team}')
                if foursome.has_phantom and phantom_team is not None:
                    _phantom_foursomes_to_configure.append(
                        (foursome, phantom_team)
                    )
                    print(f'[nassau setup] queued phantom setup for foursome {foursome.id}')

                # Ensure 'nassau' is in the foursome's active_games so
                # the score entry screen loads the Nassau summary.
                existing_games = list(foursome.active_games or [])
                if 'nassau' not in existing_games:
                    existing_games.append('nassau')
                    foursome.active_games = existing_games
                    foursome.save(update_fields=['active_games'])

            # Irish Rumble: flag active_games so _recalculate_games fires the
            # calculator after every score submission.
            elif fs_data['game_type'] == GameType.IRISH_RUMBLE:
                existing_games = list(foursome.active_games or [])
                if 'irish_rumble' not in existing_games:
                    existing_games.append('irish_rumble')
                    foursome.active_games = existing_games
                    foursome.save(update_fields=['active_games'])

            # Cup singles (18-hole overall only, pv×2 per foursome).
            elif fs_data['game_type'] == GameType.SINGLES_18:
                from services.cup_singles import setup_cup_singles
                _matchups = fs_data.get('singles_matchups') or []
                try:
                    setup_cup_singles(foursome, team1, team2,
                                      singles_matchups=_matchups)
                except (ValueError, Exception) as _e:
                    import logging
                    logging.getLogger(__name__).warning(
                        'cup singles setup failed for foursome %s: %s', foursome.id, _e)
                existing_games = list(foursome.active_games or [])
                if 'singles_18' not in existing_games:
                    existing_games.append('singles_18')
                    foursome.active_games = existing_games
                    foursome.save(update_fields=['active_games'])

            # Cup singles Nassau (F9/B9/Overall per match, pv×6 per foursome).
            elif fs_data['game_type'] == GameType.SINGLES_NASSAU:
                from services.cup_singles import setup_cup_singles
                _matchups = fs_data.get('singles_matchups') or []
                try:
                    setup_cup_singles(foursome, team1, team2,
                                      singles_matchups=_matchups)
                except (ValueError, Exception) as _e:
                    import logging
                    logging.getLogger(__name__).warning(
                        'cup singles setup failed for foursome %s: %s', foursome.id, _e)
                existing_games = list(foursome.active_games or [])
                if 'singles_nassau' not in existing_games:
                    existing_games.append('singles_nassau')
                    foursome.active_games = existing_games
                    foursome.save(update_fields=['active_games'])

            elif fs_data['game_type'] == GameType.QUOTA_NASSAU:
                # Auto-pair: team1[i] vs team2[i] cross-team 1v1 matches
                from services.quota_nassau import setup_quota_nassau
                real_pids_qn = set(
                    foursome.memberships.filter(player__is_phantom=False)
                    .values_list('player_id', flat=True)
                )
                t1_players = [p for p in (team1.players.all() if team1 else [])
                              if p.pk in real_pids_qn]
                t2_players = [p for p in (team2.players.all() if team2 else [])
                              if p.pk in real_pids_qn]

                # Detect phantom: same logic as Nassau — fill under-represented team
                qn_phantom_team = None
                if foursome.has_phantom:
                    t1_all_pids = set(team1.players.values_list('id', flat=True)) if team1 else set()
                    t2_all_pids = set(team2.players.values_list('id', flat=True)) if team2 else set()
                    phantom_pid_qn = foursome.memberships.filter(
                        player__is_phantom=True
                    ).values_list('player_id', flat=True).first()
                    if phantom_pid_qn:
                        t1_real_count = len(real_pids_qn & t1_all_pids)
                        t2_real_count = len(real_pids_qn & t2_all_pids)
                        if t1_real_count < t2_real_count:
                            # Phantom fills Team 1 — append a fake player object
                            from core.models import Player as _Player
                            _ph_player = _Player.objects.get(pk=phantom_pid_qn)
                            t1_players = t1_players + [_ph_player]
                            qn_phantom_team = team1
                        else:
                            from core.models import Player as _Player
                            _ph_player = _Player.objects.get(pk=phantom_pid_qn)
                            t2_players = t2_players + [_ph_player]
                            qn_phantom_team = team2

                # Pre-compute phantom quota: 36 − round(avg donor course_handicap)
                phantom_quota_qn = None
                if foursome.has_phantom and qn_phantom_team is not None:
                    from tournament.models import FoursomeMembership as _FM
                    _team_pids = set(
                        qn_phantom_team.players.values_list('id', flat=True)
                    )
                    _donor_hcps = list(
                        _FM.objects
                        .filter(
                            foursome__round=round_obj,
                            player_id__in=_team_pids,
                            player__is_phantom=False,
                        )
                        .exclude(foursome=foursome)
                        .values_list('course_handicap', flat=True)
                    )
                    if _donor_hcps:
                        _avg = sum(_donor_hcps) / len(_donor_hcps)
                        phantom_quota_qn = max(0, 36 - round(_avg))

                def _quota_qn(player):
                    if getattr(player, 'is_phantom', False):
                        return phantom_quota_qn if phantom_quota_qn is not None else 18
                    return _quota_for_player(foursome, player.pk)

                pairings = []
                for i in range(min(len(t1_players), len(t2_players))):
                    p1 = t1_players[i]
                    p2 = t2_players[i]
                    pairings.append({
                        'player1_id'   : p1.pk,
                        'player1_quota': _quota_qn(p1),
                        'player2_id'   : p2.pk,
                        'player2_quota': _quota_qn(p2),
                    })
                if pairings:
                    setup_quota_nassau(foursome, pairings)

                print(f'[quota_nassau setup] foursome={foursome.id} has_phantom={foursome.has_phantom} phantom_team={qn_phantom_team}')
                if foursome.has_phantom and qn_phantom_team is not None:
                    _phantom_foursomes_to_configure.append(
                        (foursome, qn_phantom_team)
                    )
                    print(f'[quota_nassau setup] queued phantom setup for foursome {foursome.id}')

                existing_games = list(foursome.active_games or [])
                if 'quota_nassau' not in existing_games:
                    existing_games.append('quota_nassau')
                    foursome.active_games = existing_games
                    foursome.save(update_fields=['active_games'])

        # Configure cross-foursome phantom rotation for Four Ball foursomes.
        # Done after the main loop so all foursomes have memberships and the
        # donor players (from other foursomes on the same team) are in the DB.
        phantom_setup_results = []
        if _phantom_foursomes_to_configure:
            from scoring.phantom import setup_cross_foursome_phantom
            for _ph_fs, _ph_team in _phantom_foursomes_to_configure:
                try:
                    ok = setup_cross_foursome_phantom(_ph_fs, _ph_team, round_obj)
                    phantom_setup_results.append({
                        'foursome_id': _ph_fs.id,
                        'team': _ph_team.name if _ph_team else None,
                        'success': ok,
                    })
                    print(f'[phantom setup] foursome={_ph_fs.id} team={_ph_team.name if _ph_team else None} ok={ok}')
                except Exception as _e:
                    import logging, traceback
                    logging.getLogger(__name__).warning(
                        'cross-foursome phantom setup failed for foursome %s: %s',
                        _ph_fs.id, _e,
                    )
                    print(f'[phantom setup] EXCEPTION foursome={_ph_fs.id}: {_e}\n{traceback.format_exc()}')
                    phantom_setup_results.append({
                        'foursome_id': _ph_fs.id,
                        'error': str(_e),
                        'success': False,
                    })
        else:
            print(f'[phantom setup] no phantom foursomes to configure (_phantom_foursomes_to_configure is empty)')

        # Ensure 'quota_nassau' appears in round.active_games when any
        # foursome is configured for it (so _build_leaderboard picks it up).
        has_qn = any(
            fs_d['game_type'] == GameType.QUOTA_NASSAU
            for fs_d in d.get('foursomes', [])
        )
        if has_qn:
            round_games = list(round_obj.active_games or [])
            if 'quota_nassau' not in round_games:
                round_games.append('quota_nassau')
                round_obj.active_games = round_games
                round_obj.save(update_fields=['active_games'])

        # Auto-create IrishRumbleConfig for cup rounds that include Irish Rumble
        # foursomes.  Without this, calculate_irish_rumble() and the ryder_cup
        # points extractor both silently return [] and the leaderboard shows
        # "Irish Rumble not configured for this round."
        has_ir = any(
            fs_d['game_type'] == GameType.IRISH_RUMBLE
            for fs_d in d.get('foursomes', [])
        )
        if has_ir:
            from games.models import IrishRumbleConfig
            IrishRumbleConfig.objects.update_or_create(
                round = round_obj,
                defaults = dict(
                    handicap_mode = round_obj.handicap_mode,
                    net_percent   = round_obj.net_percent,
                    entry_fee     = 0,
                    payouts       = [],
                    segments      = [
                        {'start_hole': 1,  'end_hole': 6,  'balls_to_count': 1},
                        {'start_hole': 7,  'end_hole': 12, 'balls_to_count': 2},
                        {'start_hole': 13, 'end_hole': 17, 'balls_to_count': 3},
                        {'start_hole': 18, 'end_hole': 18, 'balls_to_count': 4},
                    ],
                ),
            )

        # Irish Rumble cross-group pairings
        for ir_data in d.get('irish_rumble_pairings', []):
            RyderCupIrishRumblePairing.objects.create(
                round_config  = rc,
                foursome_a    = get_object_or_404(Foursome, pk=ir_data['foursome_a_id']),
                foursome_b    = get_object_or_404(Foursome, pk=ir_data['foursome_b_id']),
                team_a        = get_object_or_404(TournamentTeam, pk=ir_data['team_a_id'], tournament=tt),
                team_b        = get_object_or_404(TournamentTeam, pk=ir_data['team_b_id'], tournament=tt),
            )

        # ── Auto-populate format_declarations ─────────────────────────────────
        # Compute total possible points from the foursome game types so the
        # standings screen never needs a manual admin override.
        #
        # Irish Rumble: every *pair* of foursomes produces 1 set of points
        # (pv × 1). The number of pairings equals len(irish_rumble_pairings)
        # when pairings are explicit, or foursome_count // 2 as a fallback.
        # All other games: each foursome produces its own multiplied points.
        from collections import Counter
        foursomes_payload = d.get('foursomes', [])
        game_counts = Counter(str(fs_d['game_type']) for fs_d in foursomes_payload)
        pv_str = str(round(float(d['nassau_point_value']), 2))

        declarations = []
        for game_type_str, count in game_counts.items():
            if game_type_str == GameType.IRISH_RUMBLE:
                # Each IR foursome pair is one contest; use explicit pairings
                # count if available, otherwise divide foursome count by 2.
                ir_pairings = d.get('irish_rumble_pairings', [])
                units = len(ir_pairings) if ir_pairings else (count // 2)
            else:
                # nassau, quota_nassau, singles_nassau, singles_18:
                # each foursome is an independent contest.
                units = count
            if units > 0:
                declarations.append({
                    'game_type'  : game_type_str,
                    'units'      : units,
                    'point_value': pv_str,
                })

        rc.format_declarations = declarations
        rc.save(update_fields=['format_declarations'])

        resp = _round_ryder_config(rc)
        resp['_phantom_setup_debug'] = phantom_setup_results
        return Response(resp, status=status.HTTP_201_CREATED)


class RyderCupRoundResultView(APIView):
    """
    GET  /api/rounds/<pk>/ryder-cup/
        Return the current Ryder Cup points breakdown for this round.

    POST /api/rounds/<pk>/ryder-cup/calculate/
        (Re)calculate Ryder Cup points from current game results.
        Call this after scores have been entered and game calculators run.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)
        try:
            rc = round_obj.ryder_cup_config
        except RyderCupRoundConfig.DoesNotExist:
            return Response(
                {'detail': 'No Ryder Cup config for this round.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(_round_ryder_config(rc))


class CupRoundLiveView(APIView):
    """
    GET /api/rounds/<pk>/cup-live/

    Live Ryder Cup standings for a specific round, computed directly from
    game models (no stored RyderCupMatchPoints required).  Always returns
    fresh data — the leaderboard Cup tab calls this on every open.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)
        from services.cup_standings import cup_round_live_summary
        summary = cup_round_live_summary(round_obj)
        if summary is None:
            return Response(
                {'detail': 'No cup config for this round.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


class RyderCupRoundCalculateView(APIView):
    """
    POST /api/rounds/<pk>/ryder-cup/calculate/
    Trigger a point recalculation.  Returns the updated round breakdown.
    """
    permission_classes = [IsAuthenticated]

    @transaction.atomic
    def post(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)
        try:
            rc = round_obj.ryder_cup_config
        except RyderCupRoundConfig.DoesNotExist:
            return Response(
                {'detail': 'No Ryder Cup config for this round.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        # Rebuild every game's intermediate results from raw hole scores first
        # (e.g. MatchPlayHoleResult for cup-singles foursomes), then finalize
        # cup points.  This ensures a manual score edit in the admin is picked
        # up without needing a full score re-submission.
        for foursome in round_obj.foursomes.prefetch_related(
            'memberships', 'match_play_brackets'
        ):
            _recalculate_games(foursome)
        # _recalculate_games calls calculate_ryder_cup_points once per foursome;
        # run it one final time to guarantee all foursomes are reflected.
        calculate_ryder_cup_points(round_obj)
        return Response(_round_ryder_config(rc))


# ---------------------------------------------------------------------------
# Quota Nassau game
# ---------------------------------------------------------------------------

class QuotaNassauSetupView(APIView):
    """
    POST /api/foursomes/<pk>/quota-nassau/setup/

    Create (or replace) the QuotaNassauGame for this foursome.
    If player_quota values are omitted they are auto-calculated from the
    stored course_handicap on FoursomeMembership (36 − course_handicap).
    """
    permission_classes = [IsAuthenticated]

    @transaction.atomic
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        ser = QuotaNassauSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        pairings = []
        for p in ser.validated_data['pairings']:
            pairings.append({
                'player1_id'   : p['player1_id'],
                'player2_id'   : p['player2_id'],
                'player1_quota': (
                    p.get('player1_quota')
                    if p.get('player1_quota') is not None
                    else _quota_for_player(foursome, p['player1_id'])
                ),
                'player2_quota': (
                    p.get('player2_quota')
                    if p.get('player2_quota') is not None
                    else _quota_for_player(foursome, p['player2_id'])
                ),
            })

        game = setup_quota_nassau(foursome, pairings)

        # Mark the game as active on the foursome
        active = list(foursome.active_games or [])
        if 'quota_nassau' not in active:
            active.append('quota_nassau')
            foursome.active_games = active
            foursome.save(update_fields=['active_games'])

        return Response(
            quota_nassau_summary(foursome),
            status=status.HTTP_201_CREATED,
        )


class QuotaNassauResultView(APIView):
    """
    GET /api/foursomes/<pk>/quota-nassau/
    Return the current Quota Nassau summary for this foursome.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        summary  = quota_nassau_summary(foursome)
        if summary is None:
            return Response(
                {'detail': 'No Quota Nassau game set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


# ---------------------------------------------------------------------------
# Team tournament internal helpers
# ---------------------------------------------------------------------------

def _team_roster(team: TournamentTeam) -> dict:
    return {
        'team_id'    : team.pk,
        'team_number': team.team_number,
        'name'       : team.name,
        'colour'     : team.colour,
        'short_code' : team.short_code,
        'players'    : [
            {'player_id': p.id, 'name': p.name, 'short_name': p.short_name}
            for p in team.players.all()
        ],
    }


def _team_tournament_detail(tt: TeamTournament) -> dict:
    return {
        'id'              : tt.pk,
        'cup_name'        : tt.cup_name,
        'players_per_team': tt.players_per_team,
        'draft_complete'  : tt.draft_complete,
        'teams'           : [_team_roster(t) for t in tt.teams.order_by('team_number')],
    }


def _round_ryder_config(rc: RyderCupRoundConfig) -> dict:
    """Serialise a RyderCupRoundConfig + its current match points."""
    match_groups: dict = {}
    for mp in rc.match_points.select_related(
        'team1', 'team2', 'foursome', 'player1', 'player2'
    ).all():
        source_key = ('fs', mp.foursome_id) if mp.foursome_id else ('ir', mp.irish_rumble_pairing_id)
        key = (source_key, mp.game_type, mp.player1_id, mp.player2_id)
        match_groups.setdefault(key, []).append(mp)

    SEGMENT_ORDER = ['front9', 'back9', 'overall']
    matches_out = []
    for _key, segs in match_groups.items():
        first = segs[0]
        matches_out.append({
            'game_type': first.game_type,
            'group'    : first.foursome.group_number if first.foursome_id else None,
            'team1'    : first.team1.name,
            'team2'    : first.team2.name,
            'player1'  : first.player1.short_name if first.player1_id else None,
            'player2'  : first.player2.short_name if first.player2_id else None,
            'segments' : [
                {
                    'segment': mp.segment,
                    'result' : mp.result,
                    't1_pts' : float(mp.team1_points),
                    't2_pts' : float(mp.team2_points),
                }
                for mp in sorted(
                    segs,
                    key=lambda x: SEGMENT_ORDER.index(x.segment)
                    if x.segment in SEGMENT_ORDER else 99,
                )
            ],
        })

    # Per-team totals for this round only
    team_totals: dict = {}
    for mp in rc.match_points.select_related('team1', 'team2').all():
        team_totals.setdefault(mp.team1.name, 0.0)
        team_totals.setdefault(mp.team2.name, 0.0)
        team_totals[mp.team1.name] = round(team_totals[mp.team1.name] + float(mp.team1_points), 2)
        team_totals[mp.team2.name] = round(team_totals[mp.team2.name] + float(mp.team2_points), 2)

    return {
        'round_id'          : rc.round_id,
        'nassau_point_value': float(rc.nassau_point_value),
        'point_multiplier'  : float(rc.point_multiplier),
        'notes'             : rc.notes,
        'team_totals'       : [
            {'team': name, 'points': pts} for name, pts in team_totals.items()
        ],
        'matches': matches_out,
    }


# ---------------------------------------------------------------------------
# Tee-time bulk update
# ---------------------------------------------------------------------------

class TeeTimeBulkView(APIView):
    """
    PATCH /api/rounds/<pk>/tee-times/

    Body: {"tee_times": [{"group_number": 1, "tee_time": "08:00"},
                         {"group_number": 2, "tee_time": "08:10"}, ...]}

    Sets the tee_time on each Foursome identified by group_number.
    Passing null for tee_time clears it.
    Returns the updated foursomes.
    """
    def patch(self, request, pk):
        from api.serializers import TeeTimeBulkSerializer, FoursomeSerializer
        round_obj = get_object_or_404(Round, pk=pk)
        ser = TeeTimeBulkSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        updated = []
        for entry in ser.validated_data['tee_times']:
            try:
                fs = Foursome.objects.get(round=round_obj,
                                         group_number=entry['group_number'])
                fs.tee_time = entry['tee_time']
                fs.save(update_fields=['tee_time'])
                updated.append(fs)
            except Foursome.DoesNotExist:
                pass  # silently skip unknown group numbers

        return Response(FoursomeSerializer(updated, many=True).data)
