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

Sixes game
  POST   /api/foursomes/{id}/sixes/setup/  SixesSetupView
  GET    /api/foursomes/{id}/sixes/        SixesResultView

Match Play
  GET    /api/foursomes/{id}/match-play/   MatchPlayResultView
"""

from django.conf import settings
from django.contrib.auth import authenticate
from django.http import Http404, JsonResponse
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.views.decorators.csrf import csrf_exempt

from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.permissions import AllowAny, IsAuthenticated

from accounts import otp as otp_service
from accounts.scoring_access import (
    foursome_for_scorer, foursome_for_reader, round_for_scorer, round_for_reader,
    tournament_for_reader, round_for_participant,
)
from accounts.scoping import (
    account_get_or_404,
    account_qs,
    IsAccountMember,
    IsAccountAdmin,
)
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
    ThreePersonMatchSetupSerializer, MessageSerializer, VegasSetupSerializer,
    FourballSetupSerializer, HonorsSetupSerializer,
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

    # A foursome may hold more than one Nassau-family match (team Nassau +
    # Singles Match + Nassau Nine all share the NassauGame model, keyed by
    # game_type).  Recompute every configured match, driven off the rows so we
    # don't have to enumerate slugs here.
    if ('nassau' in active_games or 'nassau_nine' in active_games
            or 'match_18' in active_games):
        from services.nassau import calculate_all_nassau
        calculate_all_nassau(foursome)

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

    if 'honors' in active_games:
        from services.honors import calculate_honors
        calculate_honors(foursome)

    if 'vegas' in active_games:
        from services.vegas import calculate_vegas
        calculate_vegas(foursome)

    if 'fourball' in active_games:
        from services.fourball import calculate_fourball
        calculate_fourball(foursome)

    if 'wolf' in active_games:
        from services.wolf import calculate_wolf
        calculate_wolf(foursome)

    if 'rabbit' in active_games:
        from services.rabbit import calculate_rabbit
        calculate_rabbit(foursome)

    from games.models import ThreePersonMatch as _TPM
    _tpm_in_games = 'three_person_match' in active_games
    _tpm_exists   = _TPM.objects.filter(foursome=foursome).exists()
    if _tpm_in_games or _tpm_exists:
        from services.three_person_match import calculate_three_person_match
        calculate_three_person_match(foursome)

    # ---- Per-round ----
    # Recompute every Multi-Skins pool this round feeds — the one it hosts
    # AND any cross-round pool it's LINKED into (docs/multi-skins-cross-round.md),
    # even when this round's own active_games doesn't list multi_skins.
    from services.multi_skins import recalc_pools_for_round
    recalc_pools_for_round(round_obj)

    # Stableford standings are computed on the fly (config-aware) in
    # stableford_summary() below — no persisted recompute needed here.

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

    if 'triple_cup' in active_games:
        from services.triple_cup import calculate_triple_cup
        calculate_triple_cup(foursome)

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

    # Partial-round-aware stroke allocator, built once (predicting strokes on
    # unplayed holes below would otherwise rebuild it per cell = N+1).
    from scoring.handicap import make_strokes_fn
    strokes_fn = make_strokes_fn(foursome)

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
                'handicap_strokes' : hs.handicap_strokes  if hs
                                     else (strokes_fn(m.playing_handicap, m.tee, hole_num)
                                           if m.tee_id is not None else 0),
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
                        ph_strokes = phantom_m.handicap_strokes_on_hole(ph_si, hole_num)
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

    if 'spots' in active_games:
        from services.spots import spots_summary
        games['spots'] = {
            'label'   : 'Spots',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': spots_summary(fs)}
                for fs in foursomes
            ],
        }

    if 'multi_skins' in active_games:
        from services.multi_skins import multi_skins_summary
        games['multi_skins'] = {
            'label': 'Multi-Group Skins',
            **multi_skins_summary(round_obj),
        }
    else:
        # Cross-round pool: if this round is LINKED into a pool hosted
        # elsewhere, surface that pool's summary here too so linked-foursome
        # members see the tab (visibility-generous, docs/multi-skins-cross-round.md).
        from games.models import MultiSkinsLinkedRound
        _lr = (MultiSkinsLinkedRound.objects
               .filter(round=round_obj).select_related('game').first())
        if _lr is not None:
            from services.multi_skins import _summary_for_game
            games['multi_skins'] = {
                'label'         : 'Multi-Group Skins',
                'host_round_id' : _lr.game.round_id,
                **_summary_for_game(_lr.game),
            }

    if 'stableford' in active_games:
        from services.stableford import stableford_summary
        games['stableford'] = {
            'label': 'Stableford',
            **stableford_summary(round_obj),
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
            'label': 'Stroke Play',
            **low_net_round_summary(round_obj),
        }
    elif not ({'triple_cup', 'scramble'} & set(active_games)):
        # Every individual-ball round (casual OR tournament) gets a Low Net
        # "scores" tab — it's the only place to see each player's actual score,
        # even in a points-only game like Stableford. Excluded only for
        # team-ball formats (Triple Cup alt-shot, Scramble).
        from services.low_net_round import low_net_round_summary
        games['low_net_round'] = {
            'label': 'Stroke Play',
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
                        ir_groups.add(fs.display_name)
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
            'label'   : 'Sixes',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': sixes_summary(fs)}
                for fs in foursomes
            ],
        }

    if 'triple_cup' in active_games:
        from services.triple_cup import triple_cup_summary
        games['triple_cup'] = {
            'label'   : 'One Round Ryder Cup',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': triple_cup_summary(fs)}
                for fs in foursomes
                if triple_cup_summary(fs) is not None
            ],
        }

    # A foursome can hold more than one Nassau-family match (team Nassau +
    # Singles Match + Nassau Nine), each a NassauGame row keyed by game_type.
    # Emit one leaderboard block/tab per configured type — driven off the rows,
    # so it works whether or not the client has split match_18 into its own
    # active_games slug yet.
    from services.nassau import nassau_summary
    for _gt, _label in (('nassau',      'Four Ball'),
                        ('match_18',    'Singles Match'),
                        ('nassau_nine', 'Nassau Nine')):
        nassau_groups = []
        for fs in foursomes:
            # For cup rounds, skip foursomes assigned to a different game type.
            cup_cfg = None
            if _gt == 'nassau':
                try:
                    cup_cfg = fs.ryder_cup_foursome_config
                    if cup_cfg.game_type != GameType.NASSAU:
                        continue  # Skip; plays singles/IR/skins/etc.
                except Exception:
                    cup_cfg = None  # Not a cup foursome — include normally

            summary = nassau_summary(fs, _gt)
            if summary is None:
                continue  # this foursome isn't playing this match type

            group_entry = {
                'foursome_id' : fs.id,
                'group_number': fs.group_number,
                'summary'     : summary,
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
        if nassau_groups:
            games[_gt] = {'label': _label, 'by_group': nassau_groups}

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
            games['match_play'] = {'label': 'Mini Singles Bracket', 'by_group': mp_groups}
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

    if 'honors' in active_games:
        from services.honors import honors_summary
        games['honors'] = {
            'label'   : 'Honors',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': honors_summary(fs)}
                for fs in foursomes
            ],
        }

    if 'vegas' in active_games:
        from services.vegas import vegas_summary
        games['vegas'] = {
            'label'   : 'Las Vegas',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': vegas_summary(fs)}
                for fs in foursomes
            ],
        }

    if 'fourball' in active_games:
        from services.fourball import fourball_summary
        games['fourball'] = {
            'label'   : 'Fourball',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': fourball_summary(fs)}
                for fs in foursomes
                if fourball_summary(fs) is not None
            ],
        }

    if 'wolf' in active_games:
        from services.wolf import wolf_summary
        games['wolf'] = {
            'label'   : 'Wolf',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': wolf_summary(fs)}
                for fs in foursomes
            ],
        }

    if 'rabbit' in active_games:
        from services.rabbit import rabbit_summary
        games['rabbit'] = {
            'label'   : 'Rabbit',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': rabbit_summary(fs)}
                for fs in foursomes
            ],
        }

    # Cross-game settlement ("who owes whom") — nets every per-player-settleable
    # game into one summary.  None when the round has no nettable game (e.g. a
    # team-only Nassau round), in which case there's no Settlement tab.
    # Wrapped defensively: settlement is a derived convenience view, so a bug in
    # one game's money shape must never 500 the leaderboard / score submission
    # (it did: a Fourball/Sixes money entry missing player_id) — degrade to no
    # Settlement tab and log instead.
    from services.settlement import round_settlement
    try:
        settlement = round_settlement(round_obj)
        if settlement is not None:
            games['settlement'] = {'label': 'Settlement', **settlement}
    except Exception:
        import logging
        logging.getLogger(__name__).exception(
            'round_settlement failed for round %s', round_obj.id)

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
        # 'settlement' is a derived cross-game summary, not a real game. Keep it
        # OUT of active_games so older clients (which tab off active_games and
        # don't know the key) don't render it as a raw-JSON junk tab. New
        # clients pin the Settlement tab explicitly from games['settlement'],
        # exactly like low_net_round.
        if key == 'settlement':
            continue
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
                # Don't pass handicap_mode so the service default (SO Low)
                # applies — match-play side games run independently from
                # the round-level handicap (which is typically Net for
                # multi-foursome tournament rounds).
                from services.three_person_match import setup_three_person_match
                setup_three_person_match(
                    fs,
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
    Body: { "account_name": "Golden Glove",
            "username":     "paul",
            "password":     "..." }

    Returns:
        { "token":            "...",
          "is_staff":         bool,
          "is_account_admin": bool,
          "account": { "id": ..., "name": "Golden Glove" },
          "player":  { id, name, handicap_index, is_phantom, email, phone } }

        `player` is omitted if the user has no linked Player profile
        (admins, etc.).

    The full player profile is returned so the client doesn't have to make
    a follow-up /auth/me/ call — that second round-trip was responsible for
    a mid-login failure mode where a transient hiccup on me() left the user
    half-logged-in and forced a re-login.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        # Password login is deactivated — phone-OTP is the sole sign-in path.
        # Reversible via PASSWORD_LOGIN_ENABLED=true (settings). Returns 403 so
        # even older app builds that still show the password screen fail closed
        # with a clear message rather than authenticating.
        if not getattr(settings, 'PASSWORD_LOGIN_ENABLED', False):
            return Response(
                {'detail': 'Password sign-in is no longer supported. '
                           'Please sign in with your phone number.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        account_name = request.data.get('account_name', '').strip()
        username     = request.data.get('username', '').strip()
        password     = request.data.get('password', '').strip()

        if not account_name or not username or not password:
            return Response(
                {'detail': 'account_name, username and password are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user = authenticate(
            request,
            account_name=account_name,
            username=username,
            password=password,
        )
        if user is None:
            return Response(
                {'detail': 'Invalid credentials.'},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        token, _ = Token.objects.get_or_create(user=user)

        body = {
            'token':            token.key,
            'username':         user.username,
            'is_staff':         user.is_staff,
            'is_account_admin': user.is_account_admin,
            'is_support': user.is_support,
            'account': {
                'id':   user.account_id,
                'name': user.account.name,
                'created_at': user.account.created_at,
            },
        }
        try:
            body['player'] = PlayerSerializer(user.player_profile).data
        except Exception:
            pass  # user has no linked Player profile
        return Response(body)


class OtpRequestView(APIView):
    """
    POST /api/auth/otp/request/
    Body: { "phone": "415-555-0123" }

    Sends a one-time login passcode by SMS.  Phone-first identity from the
    freemium design §12: the verified cell number is the primary credential.

    Returns:
        { "sent": true,
          "debug_code": "123456" }   # only present when settings.DEBUG

    `debug_code` lets dev / automated tests complete the flow without a real
    SMS provider; it is never included in production responses.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        try:
            _phone, code = otp_service.request_code(request.data.get('phone', ''))
        except otp_service.OtpError as exc:
            return Response({'detail': str(exc)},
                            status=status.HTTP_400_BAD_REQUEST)
        body = {'sent': True}
        # `code` is None on the Twilio Verify backend (Twilio owns the code), so
        # only echo it for the local backend under DEBUG.
        if settings.DEBUG and code:
            body['debug_code'] = code
        return Response(body)


class OtpVerifyView(APIView):
    """
    POST /api/auth/otp/verify/
    Body: { "phone": "415-555-0123", "code": "123456", "name": "Paul" }

    Verifies the passcode and logs the user in.  An unknown phone SELF-CREATES
    an Account + admin User + linked Player (`name` seeds the new account /
    player; optional).

    Returns the same shape as LoginView plus `is_new_account`:
        { "token", "username", "is_staff", "is_account_admin",
          "account": {...}, "player": {...}, "is_new_account": bool }
    """
    permission_classes = [AllowAny]

    def post(self, request):
        try:
            user, is_new = otp_service.verify_code(
                request.data.get('phone', ''),
                request.data.get('code', ''),
                name=request.data.get('name', ''),
            )
        except otp_service.OtpError as exc:
            return Response({'detail': str(exc)},
                            status=status.HTTP_400_BAD_REQUEST)

        token, _ = Token.objects.get_or_create(user=user)
        body = {
            'token':            token.key,
            'username':         user.username,
            'is_staff':         user.is_staff,
            'is_account_admin': user.is_account_admin,
            'is_support': user.is_support,
            'is_new_account':   is_new,
            'account': {
                'id':   user.account_id,
                'name': user.account.name,
                'created_at': user.account.created_at,
            },
        }
        try:
            body['player'] = PlayerSerializer(user.player_profile).data
        except Exception:
            pass  # user has no linked Player profile
        return Response(body)


class InviteView(APIView):
    """
    GET /api/invite/

    The caller's personal invite link + a ready-to-send message.  The mobile
    app feeds `share_text` into the native share sheet so the user texts it from
    their OWN phone (user-initiated → TCPA / App Store safe; freemium §12).

    Returns: { "code": "ABC23XYZ",
               "url": "https://.../i/ABC23XYZ/",
               "share_text": "Join me on Halved ... <url>" }
    """
    permission_classes = [IsAuthenticated]

    def get(self, request):
        code = request.user.ensure_invite_code()
        url  = request.build_absolute_uri(f'/i/{code}/')
        share_text = (
            'Join me on Halved — the easiest way to track golf bets with your '
            f'group. {url}'
        )
        return Response({'code': code, 'url': url, 'share_text': share_text})


class GameSuggestionView(APIView):
    """
    POST /api/game-suggestions/

    A user's request to add a new game. Free-form, with prompts for the
    details we need (players, rounds, per-hole scoring, betting). Stored for
    review in the Django admin; forwarding to info@halved.golf is a deferred
    enhancement (no server email backend is wired up yet).
    """
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from api.serializers import GameSuggestionSerializer
        ser = GameSuggestionSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data
        # Require something descriptive so we don't store empty notes.
        if not any(str(d.get(f, '')).strip() for f in
                   ('game_name', 'notes', 'hole_scoring', 'betting')):
            return Response(
                {'detail': 'Please describe the game you have in mind.'},
                status=status.HTTP_400_BAD_REQUEST)

        player = getattr(request.user, 'player_profile', None)
        submitter_name = (getattr(player, 'name', '') or '').strip()
        # Email is required so we can follow up (falls back to the account email
        # if the form left it blank). The serializer's EmailField already
        # rejects a malformed address; this guards the empty case.
        contact_email = (d.get('contact_email')
                         or getattr(request.user, 'email', '') or '').strip()
        if not contact_email:
            return Response(
                {'detail': 'Please include an email address so we can follow up.'},
                status=status.HTTP_400_BAD_REQUEST)
        obj = ser.save(
            account=request.user.account,
            submitted_by=request.user,
            submitter_name=submitter_name,
            contact_email=contact_email,
        )
        # Deferred: notify info@halved.golf once a server email backend exists.
        return Response(GameSuggestionSerializer(obj).data,
                        status=status.HTTP_201_CREATED)


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
    """GET /api/auth/me/ — current user info (account, is_staff, optional player)."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        body = {
            'username':         request.user.username,
            'is_staff':         request.user.is_staff,
            'is_account_admin': request.user.is_account_admin,
            'is_support': request.user.is_support,
            'account': {
                'id':   request.user.account_id,
                'name': request.user.account.name,
                'created_at': request.user.account.created_at,
            },
        }
        try:
            body['player'] = PlayerSerializer(request.user.player_profile).data
        except Exception:
            body['player'] = None
        return Response(body)


class DeleteAccountView(APIView):
    """
    DELETE /api/auth/delete-account/

    Self-service account deletion required by App Store Guideline 5.1.1(v):
    a logged-in user must be able to delete the account they created from
    inside the app.

    Behaviour (see CLAUDE.md "in-app account deletion" decision):
      * Deletes the caller's User + auth token (login is gone, can't sign in).
      * The linked Player is UNLINKED and anonymized — personal data
        (email / phone / name) is scrubbed but the row and its golf history
        are kept, because HoleScore / FoursomeMembership reference Player
        with on_delete=PROTECT and that history is shared with other golfers
        in the account.  Other players' scorecards keep rendering with a
        neutral "Former Player" label.
      * The Account (tenant) is left intact even if it becomes memberless —
        deleting it would cascade into PROTECT-locked scores.

    Guard: a sole admin of an account that still has other members may not
    delete themselves (it would orphan those members in an admin-less
    account).  They must promote another admin first.  A solo user — the
    only member of their account — can always delete.
    """
    permission_classes = [IsAuthenticated]

    def delete(self, request):
        user    = request.user
        account = user.account

        other_members = (
            type(user).objects
            .filter(account=account, is_active=True)
            .exclude(pk=user.pk)
        )
        if (
            user.is_account_admin
            and other_members.exists()
            and not other_members.filter(is_account_admin=True).exists()
        ):
            return Response(
                {'detail': 'You are the only admin in this account.  '
                           'Promote another member to admin before '
                           'deleting your account.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Unlink + anonymize the linked Player (keep protected history).
        try:
            player = user.player_profile
        except Exception:
            player = None
        if player is not None:
            player.user       = None
            player.name       = 'Former Player'
            player.short_name = 'FP'
            player.email      = ''
            player.phone      = ''
            player.save()

        # Clear the login phone before deleting so the number is freed for
        # re-registration immediately (deleting the row releases the unique
        # index too, but this is explicit and defensive).
        if user.phone is not None:
            user.phone = None
            user.phone_verified_at = None
            user.save(update_fields=['phone', 'phone_verified_at'])

        # Drop any push tokens for this device/user.
        user.device_tokens.all().delete()

        # Drop the auth token, then the user.
        try:
            user.auth_token.delete()
        except Exception:
            pass
        user.delete()

        return Response(status=status.HTTP_204_NO_CONTENT)


# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

class PlayerListView(APIView):
    def get(self, request):
        players = list(
            Player.objects
            .for_account(request.user.account)
            .filter(is_phantom=False)
            .order_by('name')
        )
        # "On the app" = a registered user's verified phone matches this
        # golfer's normalized phone; that user's profile also carries the
        # authoritative handicap index for connected golfers.
        data = PlayerSerializer(
            players, many=True, context=_on_app_context(players),
        ).data
        return Response(data)

    def post(self, request):
        # Roster management (create) is admin-only, matching delete and
        # the member-management endpoints.  Non-admins get a read-only
        # roster in the app.
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only admins can add players.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        ser = PlayerCreateSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        # account is injected via save() so the client can never
        # spoof which tenant a new Player belongs to.
        player = ser.save(account=request.user.account)
        # Compute is_on_app / authoritative index so a golfer added via
        # "Add Halved golfer" is flagged immediately, not only after the
        # next My Golfers reload.
        return Response(
            PlayerSerializer(player, context=_on_app_context([player])).data,
            status=status.HTTP_201_CREATED,
        )


class PlayerDetailView(APIView):
    def get(self, request, pk):
        player = account_get_or_404(
            Player, request.user.account, pk=pk, is_phantom=False,
        )
        return Response(
            PlayerSerializer(player, context=_on_app_context([player])).data)

    def patch(self, request, pk):
        player = account_get_or_404(
            Player, request.user.account, pk=pk, is_phantom=False,
        )
        # Admins may edit anyone; every golfer may edit their OWN profile
        # (name / handicap / home course), which is what the Profile screen does.
        is_own = player.user_id == request.user.id
        if not (is_own or request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only admins can edit players.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        before_index = player.handicap_index
        ser = PlayerSerializer(player, data=request.data, partial=True)
        ser.is_valid(raise_exception=True)
        player = ser.save()
        # Editing a CANONICAL profile (a real account member, Player.user set)
        # propagates the new index to friends' login-less copies; editing a
        # friend's copy (no linked user) stays local.
        if (player.user_id is not None
                and 'handicap_index' in request.data
                and player.handicap_index != before_index):
            propagate_canonical_index(player)
        return Response(
            PlayerSerializer(player, context=_on_app_context([player])).data)

    def delete(self, request, pk):
        """
        DELETE /api/players/{id}/ — remove a player from the roster.

        Admin-only (is_staff OR is_account_admin).  Players who have
        played any rounds are protected by FoursomeMembership /
        HoleScore FKs and can't be hard-deleted; we surface that as a
        clear 400 so the client can show a helpful message rather
        than a raw 500.

        Phantom rows are managed by round setup and never deletable
        from this endpoint.
        """
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only admins can delete players.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        player = account_get_or_404(
            Player, request.user.account, pk=pk, is_phantom=False,
        )
        from django.db.models import ProtectedError
        try:
            player.delete()
        except ProtectedError:
            return Response(
                {'detail': f'{player.name} has played in rounds and '
                           'can\'t be removed.  Remove or archive '
                           'their rounds first.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(status=status.HTTP_204_NO_CONTENT)


class CourseListView(APIView):
    def get(self, request):
        courses = (
            Course.objects
            .for_account(request.user.account)
            .prefetch_related('tees')
            .order_by('name')
        )
        return Response(CourseSerializer(courses, many=True).data)


class RecentCoursesView(APIView):
    """
    GET /api/courses/recent/

    The account's most recently played DISTINCT courses (up to 3, newest
    first). Drives the course picker's recents quick-pick — tap one to select
    it instantly (it's already an account course). Empty list when the account
    has no rounds yet.
    """
    def get(self, request):
        from tournament.models import Round
        recent_ids, seen = [], set()
        for cid in (Round.objects
                    .filter(account=request.user.account)
                    .order_by('-date', '-created_at')
                    .values_list('course_id', flat=True)):
            if cid in seen:
                continue
            seen.add(cid)
            recent_ids.append(cid)
            if len(recent_ids) >= 3:
                break
        if not recent_ids:
            return Response([])
        # Re-sort the fetched rows back into recency order (the IN query won't
        # preserve it).
        by_id = {c.id: c for c in
                 Course.objects.filter(id__in=recent_ids).prefetch_related('tees')}
        ordered = [by_id[cid] for cid in recent_ids if cid in by_id]
        return Response(CourseSerializer(ordered, many=True).data)


class CourseDetailView(APIView):
    """GET / DELETE /api/courses/{id}/."""

    def get(self, request, pk):
        course = account_get_or_404(
            Course, request.user.account, pk=pk,
            base=Course.objects.prefetch_related('tees'),
        )
        return Response(CourseSerializer(course).data)

    def delete(self, request, pk):
        """
        Admin-only.  Course → Tee is CASCADE, so deleting a Course
        also wipes its Tees.  Tee → FoursomeMembership is PROTECT,
        so a Course that's been used in any round can't be hard-
        deleted: we surface that as a clear 400 the client can show
        instead of a generic 500.
        """
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only admins can delete courses.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        course = account_get_or_404(
            Course, request.user.account, pk=pk,
        )
        from django.db.models import ProtectedError
        try:
            course.delete()
        except ProtectedError:
            return Response(
                {'detail': f'{course.name} has been used in rounds and '
                           'can\'t be removed.  Delete or archive '
                           'those rounds first.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(status=status.HTTP_204_NO_CONTENT)


class TeeListView(APIView):
    def get(self, request):
        # Current revisions only — retired (superseded) tees stay reachable by
        # id for the rounds that used them, but aren't offered for new setups.
        tees = account_qs(Tee, request.user.account).filter(
            superseded_by__isnull=True,
        ).order_by('course__name', 'tee_name')
        return Response(TeeSerializer(tees, many=True).data)


class TeeDetailView(APIView):
    """GET / DELETE /api/tees/{id}/."""

    def get(self, request, pk):
        tee = account_get_or_404(
            Tee, request.user.account, pk=pk,
            base=Tee.objects.select_related('course'),
        )
        return Response(TeeSerializer(tee).data)

    def delete(self, request, pk):
        """
        Admin-only.  Removes a single tee set from a course (useful
        when a course discontinues a colour, etc.).  Tee →
        FoursomeMembership is PROTECT, so a tee that's been
        assigned to any player in any round returns a clean 400.
        """
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only admins can delete tees.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        tee = account_get_or_404(
            Tee, request.user.account, pk=pk,
            base=Tee.objects.select_related('course'),
        )
        from django.db.models import ProtectedError
        try:
            tee.delete()
        except ProtectedError:
            return Response(
                {'detail': f'The {tee.tee_name} tees at {tee.course.name} '
                           'have been used in rounds and can\'t be '
                           'removed.  Delete those rounds first.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(status=status.HTTP_204_NO_CONTENT)


# ---------------------------------------------------------------------------
# Tournaments
# ---------------------------------------------------------------------------

class TournamentListView(APIView):
    def get(self, request):
        tournaments = (
            Tournament.objects
            .for_account(request.user.account)
            .prefetch_related('rounds__course')
            .order_by('-start_date')
        )
        return Response(TournamentSerializer(tournaments, many=True).data)

    def post(self, request):
        """POST /api/tournaments/ — create a new tournament (staff only)."""
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only staff members can create tournaments.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        ser = TournamentCreateSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data
        tournament = Tournament.objects.create(
            account      = request.user.account,
            name         = d['name'],
            start_date   = d['start_date'],
            active_games = d['active_games'],
            total_rounds = d['total_rounds'],
        )
        return Response(TournamentSerializer(tournament).data,
                        status=status.HTTP_201_CREATED)


class TournamentDetailView(APIView):
    def get(self, request, pk):
        tournament = account_get_or_404(
            Tournament, request.user.account, pk=pk,
            base=Tournament.objects.prefetch_related('rounds__course'),
        )
        return Response(TournamentSerializer(tournament).data)

    def delete(self, request, pk):
        """DELETE /api/tournaments/{id}/ — remove tournament and all associated data (staff only)."""
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only staff members can delete tournaments.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        tournament = account_get_or_404(
            Tournament, request.user.account, pk=pk,
        )
        # Round.tournament is on_delete=SET_NULL, so tournament.delete() alone
        # would ORPHAN the rounds (tournament→NULL) rather than remove them —
        # and orphaned rounds then resurface in the casual-rounds list
        # (CasualRoundListView filters tournament__isnull=True).  Explicitly
        # delete the rounds first so this endpoint honors its "all associated
        # data / all its rounds" contract (the mobile confirm dialog warns the
        # user their scores will be permanently lost).  Round deletion cascades
        # to foursomes / memberships / hole scores / per-game configs.
        with transaction.atomic():
            tournament.rounds.all().delete()
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
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
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
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
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
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
        from services.low_net_championship import low_net_championship_summary
        return Response(low_net_championship_summary(tournament))


class TournamentStablefordSetupView(APIView):
    """GET/POST /api/tournaments/{id}/stableford/setup/ — Stableford Championship
    config (editable 6-bucket table, Net%/Gross, pool payouts)."""
    _PTS = ['pts_albatross', 'pts_eagle', 'pts_birdie',
            'pts_par', 'pts_bogey', 'pts_double']

    def _dict(self, cfg):
        return {
            'configured'         : True,
            'handicap_mode'      : cfg.handicap_mode,
            'net_percent'        : cfg.net_percent,
            'entry_fee'          : float(cfg.entry_fee),
            'payouts'            : cfg.payouts or [],
            'excluded_player_ids': cfg.excluded_player_ids or [],
            **{k: getattr(cfg, k) for k in self._PTS},
        }

    @staticmethod
    def _num_players(tournament):
        from tournament.models import FoursomeMembership
        return (FoursomeMembership.objects
                .filter(foursome__round__tournament=tournament,
                        player__is_phantom=False)
                .values('player_id').distinct().count())

    def get(self, request, pk):
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
        from games.models import StablefordChampionshipConfig
        cfg = StablefordChampionshipConfig.objects.filter(
            tournament=tournament).first()
        num = self._num_players(tournament)
        if cfg is not None:
            return Response({'num_players': num, **self._dict(cfg)})
        return Response({
            'num_players': num,
            'configured': False, 'handicap_mode': 'net', 'net_percent': 100,
            'entry_fee': 0.00, 'payouts': [], 'excluded_player_ids': [],
            'pts_albatross': 5, 'pts_eagle': 4, 'pts_birdie': 3,
            'pts_par': 2, 'pts_bogey': 1, 'pts_double': 0,
        })

    def post(self, request, pk):
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
        from api.serializers import StablefordChampionshipSetupSerializer
        ser = StablefordChampionshipSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data
        from games.models import StablefordChampionshipConfig
        cfg, _ = StablefordChampionshipConfig.objects.update_or_create(
            tournament=tournament,
            defaults={
                'handicap_mode'      : d['handicap_mode'],
                'net_percent'        : d['net_percent'],
                'entry_fee'          : d['entry_fee'],
                'payouts'            : d['payouts'],
                'excluded_player_ids': d.get('excluded_player_ids', []),
                **{k: d[k] for k in self._PTS},
            },
        )
        if 'stableford_championship' not in (tournament.active_games or []):
            tournament.active_games = (list(tournament.active_games or [])
                                       + ['stableford_championship'])
            tournament.save(update_fields=['active_games'])
        return Response(self._dict(cfg), status=status.HTTP_201_CREATED)


class TournamentStablefordView(APIView):
    """GET /api/tournaments/{id}/stableford/ — cumulative Stableford standings."""
    def get(self, request, pk):
        tournament = tournament_for_reader(request.user, pk)
        from services.stableford_championship import stableford_championship_summary
        return Response(stableford_championship_summary(tournament))


class TournamentLeaderboardView(APIView):
    """
    GET /api/tournaments/{id}/leaderboard/

    Returns all active tournament-level game standings in one payload.
    Supports: low_net (Low Net Championship), match_play (Match Play summary).
    Per-round game results (Irish Rumble, Pink Ball, etc.) live on the
    per-round leaderboard endpoint (/api/rounds/{id}/leaderboard/).
    """
    def get(self, request, pk):
        # Own-account OR a phone-matched participant (scorer included). Closes
        # the prior open-by-id read while keeping cross-account scorers/viewers.
        tournament = tournament_for_reader(
            request.user, pk,
            base=Tournament.objects.prefetch_related(
                'rounds__foursomes__memberships__player',
            ),
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
                'label'  : 'Stroke Play Championship',
                **low_net_championship_summary(tournament, round_id=round_filter),
            }

        if 'stableford_championship' in active_games:
            from services.stableford_championship import stableford_championship_summary
            games['stableford_championship'] = {
                'label': 'Stableford Championship',
                **stableford_championship_summary(tournament),
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
                'label'   : 'Mini Singles Bracket',
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

        course = account_get_or_404(
            Course, request.user.account, pk=d['course_id'],
        )
        tournament = None
        if d.get('tournament_id'):
            tournament = account_get_or_404(
                Tournament, request.user.account, pk=d['tournament_id'],
            )

        # Resolve the creating player from the authenticated user (may be None
        # for admin/staff accounts that have no linked Player profile).
        created_by = getattr(request.user, 'player_profile', None)

        # Holes played (docs/hole-flexibility.md) — clamp to the course size so
        # a 9-hole course can never claim 18. A start beyond the course size
        # falls back to hole 1.
        from services.hole_plan import DEFAULT_HOLE_COUNT
        tee_counts = [len(t.holes) for t in
                      course.tees.filter(superseded_by__isnull=True) if t.holes]
        universe = max(tee_counts) if tee_counts else DEFAULT_HOLE_COUNT
        num_holes = min(d.get('num_holes', 18) or 18, universe)
        starting_hole = d.get('starting_hole', 1) or 1
        if starting_hole > universe:
            starting_hole = 1

        round_obj = Round.objects.create(
            account           = request.user.account,
            tournament        = tournament,
            round_number      = d['round_number'],
            date              = d['date'],
            course            = course,
            status            = 'pending',
            active_games      = d['active_games'],
            primary_game      = d.get('primary_game') or None,
            game_point_values = d.get('game_point_values', {}),
            cup_group_counts  = d.get('cup_group_counts', {}),
            bet_unit          = d['bet_unit'],
            handicap_mode     = d.get('handicap_mode', 'net'),
            net_percent       = d.get('net_percent', 100),
            net_max_double_bogey = d.get('net_max_double_bogey', True),
            num_holes         = num_holes,
            starting_hole     = starting_hole,
            notes             = d['notes'],
            created_by        = created_by,
        )
        return Response(RoundSerializer(round_obj).data,
                        status=status.HTTP_201_CREATED)


class RoundDetailView(APIView):
    # Shared queryset used by GET / PATCH / DELETE so the prefetches
    # stay in sync across handlers.
    _ROUND_QS = Round.objects.select_related('course').prefetch_related(
        'foursomes__memberships__player',
        'foursomes__ryder_cup_foursome_config',
    )

    def get(self, request, pk):
        # READ: own-account, a phone-matched participant/scorer, OR an invited
        # watcher (so a spectator can open the read-only scorecard from the
        # leaderboard). PATCH/DELETE below stay TD-only.
        round_obj = round_for_reader(request.user, pk, base=self._ROUND_QS)
        return Response(
            RoundSerializer(round_obj, context={'request': request}).data,
        )

    def patch(self, request, pk):
        """
        Partial update of a Round.  Currently used from the Sixes setup
        screen to let the user adjust the round-level bet_unit at the time
        they're starting a match.  RoundSerializer already exposes
        bet_unit as writable and excludes read-only fields, so we just
        delegate to it with partial=True.
        """
        round_obj = account_get_or_404(
            Round, request.user.account, pk=pk, base=self._ROUND_QS,
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
        round_obj = account_get_or_404(
            Round, request.user.account, pk=pk,
        )
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


class RoundAddSideGameView(APIView):
    """
    POST /api/rounds/<pk>/side-games/  { "game": "skins" }

    Add a SIDE game to a casual round after it's created — side games are often
    agreed at the tee box, and on a small screen they scroll off the create
    screen. Appends the game id to `active_games` (idempotent); the caller then
    routes to that game's setup screen to configure it. Casual rounds only.
    """
    def post(self, request, pk):
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
        if round_obj.tournament_id is not None:
            return Response(
                {'detail': 'Side games are added per foursome in a tournament.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        game = (request.data.get('game') or '').strip()
        if not game or game not in set(GameType.values):
            return Response(
                {'detail': 'A valid game id is required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        games = list(round_obj.active_games or [])
        if game not in games:
            games.append(game)
            round_obj.active_games = games
            round_obj.save(update_fields=['active_games'])
        return Response(
            RoundSerializer(round_obj, context={'request': request}).data,
        )


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
            .for_account(request.user.account)
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
            # player has a gross_score (phantom scores are pre-filled, so
            # they're excluded).
            max_hole = _round_current_hole(r)

            # Pick the foursome that contains the requesting player.
            # Casual rounds used to always have a single foursome, but
            # Multi-Group Skins introduced multi-foursome casual rounds —
            # returning r.foursomes.first() always took the user to group
            # 1's score-entry regardless of which group they actually play
            # in.  Fall back to the first foursome only if no membership
            # matches (legacy admin-created rounds, edge cases).
            user_fs = next(
                (fs for fs in r.foursomes.all()
                 if any(m.player_id == requesting_player.id
                        for m in fs.memberships.all())),
                None,
            )
            chosen_fs = user_fs or r.foursomes.first()

            results.append({
                'id':                   r.id,
                'date':                 r.date,
                'course_name':          r.course.name,
                'status':               r.status,
                'active_games':         r.active_games,
                'is_eighteen_hole_match': _round_is_eighteen_hole_match(r, chosen_fs),
                'bet_unit':             r.bet_unit,
                'current_hole':         max_hole or 0,
                'created_by_player_id': r.created_by_id,
                'foursome_id':          chosen_fs.id if chosen_fs else None,
                'players':              players,
            })

        ser = CasualRoundSummarySerializer(results, many=True)
        return Response(ser.data)


# Shared round-summary helpers (used by the casual list + the cross-account
# playing/scoring/watching feeds so they all describe a round the same way).

def _round_current_hole(rnd):
    """Highest hole a real (non-phantom) player has scored; 0 = not started.
    Phantom scores are pre-filled for all 18 holes, so they're excluded."""
    from scoring.models import HoleScore as HS
    return (
        HS.objects
        .filter(foursome__round=rnd, gross_score__isnull=False,
                player__is_phantom=False)
        .order_by('-hole_number')
        .values_list('hole_number', flat=True)
        .first()
    ) or 0


def _round_is_eighteen_hole_match(rnd, foursome=None):
    """A (singles) 18-Hole Match = an Overall-only Nassau played 1-v-1.

    Overall-only (no front/back bet) distinguishes it from a Singles Nassau;
    the two-player roster distinguishes it from Fourball (the 2-v-2 18-hole
    match). A 2-v-2 Overall-only Nassau is therefore NOT an 18-Hole Match.
    """
    if 'nassau' not in (rnd.active_games or []):
        return False
    fs = foursome or rnd.foursomes.first()
    if fs is None:
        return False
    ng = fs.nassau_games.filter(game_type='nassau').first()
    if ng is None:
        return False
    if not (ng.play_overall and not ng.play_front and not ng.play_back):
        return False
    real = sum(1 for m in fs.memberships.all() if not m.player.is_phantom)
    return real == 2


# How long a COMPLETED follow stays on "Shared with me" before it ages off.
# Live (in-progress / pending) follows are always kept; a watcher doesn't care
# about a game that finished a week ago, so completed ones drop after this many
# days (measured from the round's play date).
SHARED_WATCH_RETENTION_DAYS = 7


class SharedRoundsView(APIView):
    """
    GET /api/rounds/shared-with-me/?status=in_progress|complete|pending

    Read-only cross-account follows (Friends Phase 2a): casual rounds and
    tournaments in OTHER accounts that the caller was invited to WATCH (a
    Watcher record keyed by their VERIFIED phone).  Tapping a result opens the
    existing read-only leaderboard.

    NOTE: rounds you're a PLAYER in are intentionally NOT here — those live in
    your own active list (see PlayingRoundsView) and move to its Completed tab
    when closed.  "Shared with me" is purely for non-playing spectators, and
    completed follows drop off once they're from a previous date so the list
    doesn't grow without bound.
    """
    def get(self, request):
        from django.utils import timezone
        from tournament.models import Watcher, Tournament

        my_phone = getattr(request.user, 'phone', None)  # E.164, or None (legacy)
        if not my_phone:
            return Response([])

        status = request.query_params.get('status')
        def _status_ok(s):
            return status not in ('in_progress', 'complete', 'pending') or s == status

        # Completed follows drop off the observing lists SHARED_WATCH_RETENTION_DAYS
        # after the round's play date — not the same day it ended.  A short window
        # (rather than "before today") also absorbs the client/server timezone skew
        # that was dropping a round the instant it finished: a game played in the
        # evening Pacific time carries today's LOCAL date, but the server's UTC
        # clock has already rolled to tomorrow, so a "d >= today" test failed
        # immediately.  Live (in_progress / pending) follows always stay.
        import datetime as _dt
        cutoff = timezone.now().date() - _dt.timedelta(days=SHARED_WATCH_RETENTION_DAYS)
        def _recent_enough(s, d):
            return s != 'complete' or (d is not None and d >= cutoff)

        results = []
        seen_rounds = set()

        def _round_row(r):
            return {
                'id':            r.id,
                'date':          r.date,
                'course_name':   r.course.name,
                'status':        r.status,
                'active_games':  r.active_games,
                'is_eighteen_hole_match': _round_is_eighteen_hole_match(r),
                'current_hole':  _round_current_hole(r),
                'group_label':   (r.created_by.name if r.created_by_id else None)
                                 or r.account.name,
                'your_name':     None,
                'is_tournament': False,
            }

        # 1. Casual rounds I'm a WATCHER of.
        watch_round_ids = list(
            Watcher.objects.filter(phone=my_phone, round__isnull=False)
            .values_list('round_id', flat=True))
        if watch_round_ids:
            qs = (
                Round.objects.filter(id__in=watch_round_ids)
                .exclude(account=request.user.account)
                .select_related('course', 'account', 'created_by')
                .order_by('-date', '-created_at')
            )
            for r in qs:
                if (r.id in seen_rounds or not _status_ok(r.status)
                        or not _recent_enough(r.status, r.date)):
                    continue
                results.append(_round_row(r))
                seen_rounds.add(r.id)

        # 2. Tournaments I'm a WATCHER of (whole-event, read-only).
        watch_t_ids = list(
            Watcher.objects.filter(phone=my_phone, tournament__isnull=False)
            .values_list('tournament_id', flat=True))
        if watch_t_ids:
            for t in (
                Tournament.objects.filter(id__in=watch_t_ids)
                .exclude(account=request.user.account)
                .select_related('account')
                .prefetch_related('rounds__course')
            ):
                rounds = list(t.rounds.all())
                t_status = ('complete'
                            if rounds and all(rr.status == 'complete' for rr in rounds)
                            else 'in_progress')
                t_date = max((rr.date for rr in rounds if rr.date), default=None)
                if not _status_ok(t_status) or not _recent_enough(t_status, t_date):
                    continue
                results.append({
                    'id':            t.id,
                    'date':          rounds[0].date if rounds else None,
                    'course_name':   rounds[0].course.name if rounds else '',
                    'status':        t_status,
                    'active_games':  t.active_games,
                    'group_label':   t.name,
                    'your_name':     None,
                    'is_tournament': True,
                })
        return Response(results)


class ScoringForMeView(APIView):
    """
    GET /api/rounds/scoring-for-me/

    Multi-foursome rounds in OTHER accounts where a member flagged `is_scorer`
    carries the caller's VERIFIED phone — i.e. rounds a TD designated me to
    score. Phone-matched (delegated cross-account scoring). Returns the parent
    round + `your_foursome_id` so the app opens straight to my group.
    """
    def get(self, request):
        from accounts.phone import normalize

        my_phone = getattr(request.user, 'phone', None)
        if not my_phone:
            return Response([])

        rows = (
            FoursomeMembership.objects
            .filter(is_scorer=True)
            .exclude(foursome__round__account=request.user.account)
            .exclude(player__phone='')
            .select_related(
                'foursome__round__course', 'foursome__round__account',
                'foursome__round__tournament', 'foursome__round__created_by',
                'player',
            )
            .order_by('-foursome__round__date')
        )

        results, seen = [], set()
        for m in rows:
            if normalize(m.player.phone) != my_phone:
                continue
            r = m.foursome.round
            if r.id in seen:
                continue
            seen.add(r.id)
            t = r.tournament
            group_label = (
                (t.name if t is not None else None)
                or (r.created_by.name if r.created_by_id else None)
                or r.account.name
            )
            results.append({
                'id':               r.id,
                'date':             r.date,
                'course_name':      r.course.name,
                'status':           r.status,
                'active_games':     r.active_games,
                'is_eighteen_hole_match': _round_is_eighteen_hole_match(r, m.foursome),
                'current_hole':     _round_current_hole(r),
                'group_label':      group_label,
                'is_tournament':    t is not None,
                'your_foursome_id': m.foursome_id,
            })
        return Response(results)


def _resolve_support_round(q: str):
    """Resolve a Round from a watch token, a /watch/<token>/ URL, or a numeric
    round id. Returns the Round or None."""
    from tournament.models import Round
    if not q:
        return None
    if '/watch/' in q:
        q = q.split('/watch/', 1)[1].strip('/').split('/')[0]
    q = q.strip()
    base = Round.objects.select_related('course', 'tournament', 'account')
    if q.isdigit():
        return base.filter(pk=int(q)).first()
    return base.filter(watch_token=q.upper()).first()


class SupportRoundLookupView(APIView):
    """
    GET /api/support/round/?q=<watch-token | /watch/ URL | round-id>

    Support staff (User.is_support) or superusers only. Resolves a round the
    caller may not own, LOGS the access (SupportAccessLog), and returns a
    lightweight summary + the round id so the app can open it READ-ONLY through
    the normal leaderboard screen (round_for_reader now admits support staff).
    Grants no write access.
    """
    def get(self, request):
        u = request.user
        if not (getattr(u, 'is_support', False) or u.is_superuser):
            return Response({'detail': 'Support access required.'},
                            status=status.HTTP_403_FORBIDDEN)
        q = (request.query_params.get('q') or '').strip()
        rnd = _resolve_support_round(q)
        if rnd is None:
            return Response({'detail': 'No round found for that token or id.'},
                            status=status.HTTP_404_NOT_FOUND)
        from accounts.models import SupportAccessLog
        SupportAccessLog.objects.create(
            user=u, round=rnd,
            account_name=getattr(rnd.account, 'name', '') or '',
            query=q[:64],
        )
        t = rnd.tournament
        return Response({
            'round_id':        rnd.id,
            'watch_token':     rnd.watch_token,
            'date':            rnd.date,
            'status':          rnd.status,
            'course_name':     rnd.course.name if rnd.course_id else None,
            'account_name':    getattr(rnd.account, 'name', ''),
            'active_games':    rnd.active_games or [],
            'num_foursomes':   rnd.foursomes.count(),
            'is_tournament':   t is not None,
            'tournament_name': t.name if t is not None else None,
        })


class WatchTokenResolveView(APIView):
    """
    GET /api/watch/<token>/resolve/

    Called by the app when it's opened via a universal watch link
    (https://halved.golf/watch/<token>/).  Resolves the round from the token,
    records the caller as a watcher (by their verified phone — so the round
    also surfaces under "Observing" and round_for_reader admits them), and
    returns the ids the app needs to open the read-only leaderboard.
    """
    def get(self, request, token):
        from tournament.models import Round, Watcher
        rnd = (Round.objects.select_related('tournament')
               .filter(watch_token=(token or '').upper()).first())
        if rnd is None:
            return Response({'detail': 'No round found for that link.'},
                            status=status.HTTP_404_NOT_FOUND)

        # Record the opener as a watcher unless they're already playing in it.
        phone = getattr(request.user, 'phone', None)
        if phone:
            from accounts.phone import normalize
            norm = normalize(phone)
            if norm:
                _, part_phones = _round_participant_keys(rnd)
                if norm not in part_phones:
                    prof = getattr(request.user, 'player_profile', None)
                    Watcher.objects.get_or_create(
                        round=rnd, tournament=None, phone=norm,
                        defaults={'name': (prof.name if prof else 'Watcher'),
                                  'invited_by': prof})
        t = rnd.tournament
        return Response({
            'round_id':        rnd.id,
            'is_tournament':   t is not None,
            'tournament_id':   t.id if t is not None else None,
            'tournament_name': t.name if t is not None else None,
        })


class PlayingRoundsView(APIView):
    """
    GET /api/rounds/playing-for-me/

    Rounds in OTHER accounts where a player carrying my VERIFIED phone is a
    member — i.e. games a TD/friend added me to as a PLAYER (single foursome,
    multi-group skins, or tournament). Unlike `scoring-for-me` (designated
    scorers only), this is ANY phone-matched participant: the round shows up in
    my own active list so I can open it, follow my group, and read the
    leaderboard. (Whether I can ENTER scores is still gated server-side by
    scorer designation, so this never silently double-scores a shared group.)
    Watchers are NOT here — non-playing spectators stay in `shared-with-me`.
    Returns the round + `your_foursome_id` so the app opens straight to my group.
    """
    def get(self, request):
        from accounts.phone import normalize

        my_phone = getattr(request.user, 'phone', None)
        if not my_phone:
            return Response([])

        rows = (
            FoursomeMembership.objects
            .exclude(foursome__round__account=request.user.account)
            .exclude(player__phone='')
            .select_related(
                'foursome__round__course', 'foursome__round__account',
                'foursome__round__tournament', 'foursome__round__created_by',
                'player', 'foursome',
            )
            .prefetch_related('foursome__round__foursomes')
            .order_by('-foursome__round__date')
        )

        results, seen = [], set()
        for m in rows:
            if normalize(m.player.phone) != my_phone:
                continue
            r = m.foursome.round
            if r.id in seen:
                continue
            # Any round I'm a player in — single foursome, multi-group, or
            # tournament — belongs in my active list (a player expects to see
            # the game they were added to, not just follow it read-only). A
            # non-playing watcher is excluded here (no FoursomeMembership) and
            # still surfaces via shared-with-me.
            seen.add(r.id)
            t = r.tournament
            group_label = (
                (t.name if t is not None else None)
                or (r.created_by.name if r.created_by_id else None)
                or r.account.name
            )
            results.append({
                'id':               r.id,
                'date':             r.date,
                'course_name':      r.course.name,
                'status':           r.status,
                'active_games':     r.active_games,
                'is_eighteen_hole_match': _round_is_eighteen_hole_match(r, m.foursome),
                'current_hole':     _round_current_hole(r),
                'group_label':      group_label,
                'is_tournament':    t is not None,
                'your_foursome_id': m.foursome_id,
            })
        return Response(results)


class RoundJoinView(APIView):
    """
    POST /api/rounds/<pk>/join/

    Called when someone opens a shared round, to mirror the connection into
    their account (idempotent; own-account = no-op):
      * a PARTICIPANT gets the TD added to "My Golfers" + the course copied in;
      * a WATCHER just gets the person who invited them added to "My Golfers".
    """
    def post(self, request, pk):
        rnd = round_for_reader(request.user, pk)
        if rnd.account_id == request.user.account_id:
            return Response({'td_added': False, 'course_added': False})
        from services.friends_sync import (
            sync_shared_round, ensure_watch_connection)
        try:
            round_for_participant(request.user, pk)
        except Http404:
            return Response(ensure_watch_connection(request.user, round=rnd))
        return Response(sync_shared_round(request.user, rnd))


class TournamentJoinView(APIView):
    """
    POST /api/tournaments/<pk>/join/

    Called when a watcher opens a shared tournament — adds the person who
    invited them to "My Golfers". Idempotent; own-account = no-op.
    """
    def post(self, request, pk):
        t = tournament_for_reader(request.user, pk)
        if t.account_id == request.user.account_id:
            return Response({'inviter_added': False})
        from services.friends_sync import ensure_watch_connection
        return Response(ensure_watch_connection(request.user, tournament=t))


def _add_watcher(request, *, round_obj=None, tournament=None):
    """Shared body for the round/tournament watcher-add endpoints. Resolves the
    watcher's phone+name (from a roster golfer via player_id, or a raw phone),
    ensures they're in the inviter's My Golfers roster, and records the Watcher.
    """
    from accounts.phone import normalize
    from core.models import Player
    from tournament.models import Watcher
    from services.friends_sync import ensure_roster_player

    phone_raw = (request.data.get('phone') or '').strip()
    name      = (request.data.get('name') or '').strip()
    player_id = request.data.get('player_id')
    if player_id:
        p = account_get_or_404(Player, request.user.account, pk=player_id)
        phone_raw = (p.phone or phone_raw).strip()
        name = name or p.name
    if not name:
        return Response({'detail': 'A name is required to invite a watcher.'},
                        status=status.HTTP_400_BAD_REQUEST)
    if not phone_raw:
        return Response(
            {'detail': 'A phone number is required to invite a watcher.'},
            status=status.HTTP_400_BAD_REQUEST)
    norm = normalize(phone_raw)
    if not norm:
        return Response({'detail': 'Enter a valid phone number.'},
                        status=status.HTTP_400_BAD_REQUEST)

    # A current PLAYER can't also be a watcher — that would double-list the round
    # (once as "playing", once as "observing"). Playing supersedes watching.
    part_phones = set()
    if round_obj is not None:
        _, part_phones = _round_participant_keys(round_obj)
    elif tournament is not None:
        for r in tournament.rounds.all():
            _, ph = _round_participant_keys(r)
            part_phones |= ph
    if norm in part_phones:
        where = 'tournament' if tournament is not None else 'round'
        return Response(
            {'detail': f'{name} is already playing in this {where}.'},
            status=status.HTTP_400_BAD_REQUEST)

    # Put the watcher in the inviter's roster (so they can be re-invited / seen).
    # roster_created distinguishes a brand-new golfer from a phone match against
    # an existing one — the client uses it (with roster_name) to tell the user
    # exactly what happened, since a match keeps the existing (possibly older)
    # name rather than silently renaming it.
    roster_player, roster_created = ensure_roster_player(
        request.user.account, phone_raw, name)
    inviter = getattr(request.user, 'player_profile', None)
    watcher, created = Watcher.objects.get_or_create(
        round=round_obj, tournament=tournament, phone=norm,
        defaults={'name': name, 'invited_by': inviter},
    )

    # If the watcher is already on Halved, notify them IN-APP (push) — the
    # inviter shouldn't have to send them a "download Halved" text. `is_on_app`
    # is returned so the client can skip the download share for them.
    from accounts.models import User as _User
    target = _User.objects.filter(phone=norm).first()
    is_on_app = target is not None
    if created and target is not None:
        try:
            from services.push import send_push, tokens_for_users
            toks = tokens_for_users([target], 'watch_invite')
            if toks:
                who  = inviter.name if inviter else 'Someone'
                what = (round_obj.course.name if round_obj
                        else (tournament.name if tournament else 'a round'))
                send_push(toks, 'Invited to watch',
                          f'{who} invited you to follow {what}.',
                          {'type': 'watch_invite'})
        except Exception:  # best-effort — never block the invite
            import logging
            logging.getLogger(__name__).exception('watch-invite push failed')

    # Public watch link (a halved.golf universal link — opens the app to this
    # round for installed users once deep-linking is live, else the read-only
    # web watch page).  For a tournament, link the in-progress round's page (or
    # the first round) since watch tokens live on Round.
    from django.conf import settings
    base = settings.PUBLIC_BASE_URL
    watch_url = None
    watch_round = round_obj
    if watch_round is None and tournament is not None:
        watch_round = (tournament.rounds.filter(status='in_progress').first()
                       or tournament.rounds.first())
    if watch_round is not None and watch_round.watch_token:
        watch_url = f'{base}/watch/{watch_round.watch_token}/'

    return Response(
        {'watcher_id': watcher.id, 'created': created, 'is_on_app': is_on_app,
         'player_id': roster_player.id if roster_player else None,
         'roster_name': roster_player.name if roster_player else None,
         'roster_created': roster_created,
         'watch_url': watch_url,
         'download_url': settings.APP_DOWNLOAD_URL,
         'phone': norm},
        status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)


class RoundWatcherView(APIView):
    """
    POST /api/rounds/<pk>/watchers/   body {phone | player_id, name}

    Invite a non-playing spectator to follow this (casual) round in-app,
    read-only. Allowed to anyone already involved with the round — a participant
    OR an existing watcher (so the viral chain continues).
    """
    def post(self, request, pk):
        rnd = round_for_reader(request.user, pk)
        return _add_watcher(request, round_obj=rnd)


class TournamentWatcherView(APIView):
    """
    POST /api/tournaments/<pk>/watchers/   body {phone | player_id, name}

    Invite a spectator to follow a whole tournament in-app, read-only. Allowed
    to any participant or existing watcher of the tournament.
    """
    def post(self, request, pk):
        t = tournament_for_reader(request.user, pk)
        return _add_watcher(request, tournament=t)


def _round_participant_keys(rnd):
    """(player_ids, normalized_phones) of the non-phantom players in a round."""
    from accounts.phone import normalize
    ids, phones = set(), set()
    for fs in rnd.foursomes.all():
        for m in fs.memberships.all():
            p = m.player
            if p.is_phantom:
                continue
            ids.add(p.id)
            if p.phone:
                n = normalize(p.phone)
                if n:
                    phones.add(n)
    return ids, phones


def _on_app_context(players):
    """Serializer context for a set of golfers: which are On Halved (their
    normalized phone matches a registered user's verified phone)."""
    from accounts.phone import normalize
    from django.contrib.auth import get_user_model

    normalized = {normalize(p.phone) for p in players if p.phone}
    normalized.discard(None)
    on_app_phones = set()
    if normalized:
        on_app_phones = set(
            get_user_model().objects
            .filter(phone__in=normalized)
            .values_list('phone', flat=True)
        )
    return {'on_app_phones': on_app_phones}


def propagate_canonical_index(canonical):
    """Push a registered golfer's OWN profile index out to the login-less
    copies of them that friends added in other accounts (matched by normalized
    phone).  This is the write-time half of the handicap model: a golfer's copy
    is always locally editable, but when the golfer updates their OWN index it
    overwrites their friends' copies.  Friends may re-edit afterwards; the next
    self-edit overwrites again.  Returns the number of copies updated.

    `canonical` must be a real account member's profile (Player.user set).
    Phone is free-text per copy, so we normalize-match in Python; the guest-copy
    set is small, but a normalized-phone column would let this filter in SQL.
    """
    from accounts.phone import normalize
    n = normalize(canonical.phone)
    if not n:
        return 0
    copies = []
    for p in (Player.objects
              .filter(user__isnull=True, is_phantom=False)
              .exclude(pk=canonical.pk)
              .exclude(phone='')
              .only('id', 'phone', 'handicap_index')):
        if normalize(p.phone) == n and p.handicap_index != canonical.handicap_index:
            p.handicap_index = canonical.handicap_index
            copies.append(p)
    if copies:
        Player.objects.bulk_update(copies, ['handicap_index'])
    return len(copies)


def _watcher_candidates_response(request, exclude_ids, exclude_phones):
    """My roster minus anyone already PLAYING (matched by id or normalized
    phone) — so you don't invite a player to 'watch'."""
    from accounts.phone import normalize
    from .serializers import PlayerSerializer

    roster = list(
        Player.objects.for_account(request.user.account)
        .filter(is_phantom=False).order_by('name'))
    candidates = [
        p for p in roster
        if p.id not in exclude_ids
        and not (p.phone and normalize(p.phone) in exclude_phones)
    ]
    data = PlayerSerializer(candidates, many=True,
                            context=_on_app_context(candidates)).data
    return Response(data)


class RoundWatcherCandidatesView(APIView):
    """
    GET /api/rounds/<pk>/watcher-candidates/

    My Golfers eligible to invite as watchers of this round — excludes anyone
    already playing in it OR already watching it.
    """
    def get(self, request, pk):
        from tournament.models import Watcher
        rnd = round_for_reader(request.user, pk)
        ids, phones = _round_participant_keys(rnd)
        # Already-watching golfers shouldn't be offered again (Watcher.phone is
        # stored normalized, same form as the participant phones).
        phones |= set(
            Watcher.objects.filter(round=rnd).values_list('phone', flat=True))
        return _watcher_candidates_response(request, ids, phones)


class TournamentWatcherCandidatesView(APIView):
    """
    GET /api/tournaments/<pk>/watcher-candidates/
    Excludes players in any round AND existing watchers of the tournament.
    """
    def get(self, request, pk):
        from tournament.models import Watcher
        t = tournament_for_reader(request.user, pk)
        ids, phones = set(), set()
        for r in t.rounds.all():
            i, ph = _round_participant_keys(r)
            ids |= i
            phones |= ph
        phones |= set(
            Watcher.objects.filter(tournament=t).values_list('phone', flat=True))
        return _watcher_candidates_response(request, ids, phones)


class HalvedUserLookupView(APIView):
    """
    GET /api/halved-users/lookup/?phone=<number>

    Look up a registered Halved member by phone so you can add them to a round
    even if they're not in your roster yet. You must know the number — there is
    NO browsable directory, and we never return phone numbers. Returns the
    member's profile fields (to confirm + seed a local golfer); their handicap
    then follows them via the usual phone match. {found:false} when no verified
    user has that number.
    """
    def get(self, request):
        from accounts.phone import normalize
        from django.contrib.auth import get_user_model

        raw = (request.query_params.get('phone') or '').strip()
        n = normalize(raw) if raw else None
        if not n:
            return Response({'found': False})
        u = (get_user_model().objects.filter(phone=n)
             .select_related('player_profile').first())
        if u is None:
            return Response({'found': False})
        prof = getattr(u, 'player_profile', None)
        name = ((prof.name if prof else '') or u.get_full_name()
                or u.username)
        return Response({
            'found': True,
            'name': name,
            'short_name': (prof.short_name if prof else '') or '',
            'sex': (prof.sex if prof else 'M') or 'M',
            'handicap_index': str(prof.handicap_index) if prof else '0.0',
        })


class DeviceRegisterView(APIView):
    """
    POST /api/devices/register/   {token, platform}

    Register (or move) this device's push token to the current user. Idempotent;
    a token always belongs to exactly one user (handles a shared device).
    """
    def post(self, request):
        from accounts.models import DeviceToken
        token = (request.data.get('token') or '').strip()
        platform = (request.data.get('platform') or '').strip()
        if not token:
            return Response({'detail': 'token required'},
                            status=status.HTTP_400_BAD_REQUEST)
        DeviceToken.objects.update_or_create(
            token=token,
            defaults={'user': request.user, 'platform': platform})
        return Response({'ok': True})


class DeviceUnregisterView(APIView):
    """POST /api/devices/unregister/  {token} — drop a token (e.g. on logout)."""
    def post(self, request):
        from accounts.models import DeviceToken
        token = (request.data.get('token') or '').strip()
        if token:
            DeviceToken.objects.filter(
                token=token, user=request.user).delete()
        return Response({'ok': True})


class NotificationPrefsView(APIView):
    """
    GET  /api/notification-prefs/  → all categories (defaults overlaid by mine)
    PATCH same body {category: bool, ...} → merge into my prefs
    """
    def get(self, request):
        from services.push import NOTIFICATION_CATEGORIES
        prefs = dict(NOTIFICATION_CATEGORIES)
        prefs.update(request.user.notification_prefs or {})
        return Response(prefs)

    def patch(self, request):
        from services.push import NOTIFICATION_CATEGORIES
        cur = dict(request.user.notification_prefs or {})
        for k, v in (request.data or {}).items():
            if k in NOTIFICATION_CATEGORIES:
                cur[k] = bool(v)
        request.user.notification_prefs = cur
        request.user.save(update_fields=['notification_prefs'])
        merged = dict(NOTIFICATION_CATEGORIES); merged.update(cur)
        return Response(merged)


class ScorerDesignateView(APIView):
    """
    POST /api/foursomes/<pk>/scorer/
    Body: {"player_id": int, "is_scorer": true}

    TD designates (or clears, is_scorer=false) a foursome member as its scorer —
    delegated cross-account score entry. Own-account only; ≥1 scorer allowed.
    The designated member should be on the app (phone-matched), but that isn't
    enforced (they can install day-of).
    """
    def post(self, request, pk):
        foursome = account_get_or_404(Foursome, request.user.account, pk=pk)
        player_id = request.data.get('player_id')
        flag = bool(request.data.get('is_scorer', True))
        m = foursome.memberships.filter(player_id=player_id).first()
        if m is None:
            return Response(
                {'detail': 'That player is not in this foursome.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        m.is_scorer = flag
        m.save(update_fields=['is_scorer'])
        scorer_ids = list(
            foursome.memberships.filter(is_scorer=True)
            .values_list('player_id', flat=True)
        )
        return Response({'foursome_id': foursome.id,
                         'scorer_player_ids': scorer_ids})


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
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
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

        # Notify followers a multi-group round has started (once; best-effort).
        from services.push import maybe_notify_round_started
        maybe_notify_round_started(round_obj)
        from services.messaging_events import emit_round_started
        emit_round_started(round_obj)

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

    def patch(self, request, pk):
        """TD action — update this group's editable fields. Body may include:
          * "name": custom group name (blank clears → 'Group N')
          * "starting_hole": this group's SHOTGUN start (1..course holes;
            null/blank clears → inherit the round's default)
          * "shotgun_slot": display-only tee-slot label (e.g. "A"/"B") shown as
            "7A"/"7B" when two groups share a hole; blank clears
        Only the keys present in the body are touched."""
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only the organizer can edit a group.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        foursome = foursome_for_scorer(request.user, pk)
        updated = []

        if 'name' in request.data:
            name = (request.data.get('name') or '').strip()
            if len(name) > 50:
                return Response(
                    {'detail': 'Group name must be 50 characters or fewer.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            foursome.name = name
            updated.append('name')

        if 'starting_hole' in request.data:
            raw = request.data.get('starting_hole')
            if raw in (None, ''):
                foursome.starting_hole = None
            else:
                from services.hole_plan import course_hole_count
                universe = course_hole_count(foursome.round)
                try:
                    sh = int(raw)
                except (TypeError, ValueError):
                    return Response(
                        {'detail': 'starting_hole must be a whole number.'},
                        status=status.HTTP_400_BAD_REQUEST,
                    )
                if not (1 <= sh <= universe):
                    return Response(
                        {'detail': f'starting_hole must be 1–{universe}.'},
                        status=status.HTTP_400_BAD_REQUEST,
                    )
                foursome.starting_hole = sh
            updated.append('starting_hole')

        if 'shotgun_slot' in request.data:
            foursome.shotgun_slot = (
                (request.data.get('shotgun_slot') or '').strip().upper()[:2]
            )
            updated.append('shotgun_slot')

        if updated:
            foursome.save(update_fields=updated)
        return Response(FoursomeSerializer(foursome).data)


class FoursomeActiveGamesView(APIView):
    """
    PATCH /api/foursomes/{id}/active-games/
    Body: { "active_games": ["irish_rumble", "pink_ball"] }

    Sets the per-foursome game override list.  Empty list means "inherit from round".
    Staff only — regular players cannot reassign games mid-round.
    """
    def patch(self, request, pk):
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only staff members can configure foursome games.'},
                status=status.HTTP_403_FORBIDDEN,
            )
        foursome = foursome_for_scorer(request.user, pk)
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


class FoursomeTeesView(APIView):
    """
    PATCH /api/foursomes/{id}/tees/
    Body: { "tees": [{"player_id": int, "tee_id": int}, ...] }

    Reassigns each player's tee for this foursome and recomputes their
    course_handicap + playing_handicap from the new tee's slope and
    rating.  The original round-level handicap_allowance ratio is
    preserved (we infer it from the existing playing/course ratio).

    Refuses the request when any HoleScore with a gross_score exists
    for the foursome — changing a tee changes the stroke-index
    allocation, so applying new tees to already-scored holes would
    silently corrupt every saved handicap_strokes value.

    GET returns the tees AVAILABLE at this foursome's course (for the
    tee-box editor's dropdown) — sourced from the round's course, not the
    viewer's account, so a cross-account scorer sees the right options.
    Both GET and PATCH allow the round's TD OR a designated scorer.
    """
    def get(self, request, pk):
        foursome = foursome_for_scorer(
            request.user, pk,
            base=Foursome.objects.select_related('round__course'),
        )
        from core.models import Tee
        from .serializers import TeeSerializer
        tees = (
            Tee.objects
            .filter(course=foursome.round.course, superseded_by__isnull=True)
            .select_related('course')
            .order_by('sort_priority', 'tee_name')
        )
        return Response(TeeSerializer(tees, many=True).data)

    @transaction.atomic
    def patch(self, request, pk):
        foursome = foursome_for_scorer(
            request.user, pk,
            base=Foursome.objects.prefetch_related('memberships__player'),
        )

        # Phantom-player scores (Sixes phantom, Pink Ball rotation, etc.)
        # don't represent real scoring — exclude them so the lock only
        # kicks in once a real player has played a hole.
        scored = HoleScore.objects.filter(
            foursome=foursome,
            gross_score__isnull=False,
            player__is_phantom=False,
        ).exists()
        if scored:
            return Response(
                {'detail':
                 'Cannot change tees after scores have been entered for '
                 'this foursome.  Reopen the round and clear scores first.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        tees_data = request.data.get('tees', [])
        if not isinstance(tees_data, list) or not tees_data:
            return Response(
                {'detail': 'tees must be a non-empty list of '
                           '{player_id, tee_id} entries.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        from scoring.handicap import par_adjusted_playing_handicap

        memberships = {
            m.player_id: m
            for m in foursome.memberships.select_related('tee', 'player').all()
        }

        # Recover each real player's handicap allowance BEFORE any tee change,
        # backing out the current mixed-par adjustment so it isn't folded into
        # the ratio (allowance is otherwise 1.0 in practice).
        real_now = [m for m in memberships.values()
                    if not m.player.is_phantom and m.tee]
        old_min_par = min((m.tee.par for m in real_now), default=0)
        allowance_by_pid = {}
        for m in real_now:
            base = m.playing_handicap - (m.tee.par - old_min_par)
            allowance_by_pid[m.player_id] = (
                base / m.course_handicap
                if m.course_handicap and m.course_handicap > 0 else 1.0)

        updated = []
        for item in tees_data:
            if not isinstance(item, dict):
                continue
            pid = item.get('player_id')
            tid = item.get('tee_id')
            if pid is None or tid is None:
                continue
            m = memberships.get(pid)
            if m is None:
                continue
            m.tee             = get_object_or_404(Tee, pk=tid)
            m.course_handicap = m.player.course_handicap(m.tee)
            updated.append(m.player_id)

        # Recompute par-adjusted playing handicaps across the WHOLE foursome —
        # a tee change can shift the group's lowest par, so every real member's
        # adjustment is re-derived and saved.
        real = [m for m in memberships.values()
                if not m.player.is_phantom and m.tee]
        new_min_par = min((m.tee.par for m in real), default=0)
        for m in real:
            m.playing_handicap = par_adjusted_playing_handicap(
                m.course_handicap, m.tee.par, new_min_par,
                allowance_by_pid.get(m.player_id, 1.0))
            m.save(update_fields=['tee', 'course_handicap', 'playing_handicap'])

        return Response({
            'foursome_id'      : foursome.id,
            'updated_player_ids': updated,
            'scorecard'        : _build_scorecard(foursome),
        })


# ---------------------------------------------------------------------------
# Scorecard
# ---------------------------------------------------------------------------

class ScorecardView(APIView):
    def get(self, request, pk):
        # READ-only: admit watchers/spectators (and "Shared with me" participants)
        # too, so the scorecard is reachable from the leaderboard, not just by a
        # scorer mid-round.
        foursome = foursome_for_reader(
            request.user, pk,
            base=Foursome.objects
                    .select_related('round__course')
                    .prefetch_related('memberships__player'),
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
        foursome = foursome_for_scorer(request.user, pk)
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
        foursome = foursome_for_scorer(
            request.user, pk,
            base=Foursome.objects
                    .select_related('round__course')
                    .prefetch_related('memberships__player'),
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

            # gross_score=None → CLEAR this player's score on this hole. The
            # client only sends this for the trailing/current hole, so the round
            # stays a contiguous run (no mid-round gap). Deleting the row (rather
            # than nulling gross) keeps "scored?" checks simple everywhere.
            if gross is None:
                HoleScore.objects.filter(
                    foursome=foursome, player_id=pid, hole_number=hole_number,
                ).delete()
                continue

            # Per-player SI: pulled from THIS player's tee, not a shared one.
            player_hole_info = m.tee.hole(hole_number)
            stroke_index     = player_hole_info.get('stroke_index', 18)
            # Pass hole_number so a partial round scales + re-ranks the handicap.
            hcp_strokes = m.handicap_strokes_on_hole(stroke_index, hole_number)

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
        # calculator picks it up. Collect the affected phantom foursomes so we
        # can recalc THEIR games below — otherwise a donor change (incl. a
        # retroactive edit/clear) refreshes only the phantom's raw score, and
        # that foursome's stored result stays stale until it posts again (which
        # may be never, if it's finished).
        from scoring.phantom import propagate_phantom_score
        phantom_foursomes: dict = {}   # id -> Foursome
        for s in scores:
            try:
                for fs in propagate_phantom_score(
                    foursome.round, hole_number, s['player_id'], s['gross_score']
                ):
                    phantom_foursomes[fs.id] = fs
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

        # Recalc any OTHER foursome whose phantom this donor feeds, so its stored
        # result reflects the change now (not on its own next post). Best-effort.
        for fs in phantom_foursomes.values():
            if fs.id != foursome.id:
                try:
                    _recalculate_games(fs)
                except Exception:
                    pass

        # Slice 3: emit server events (birdies now; skins/matches next) — runs
        # after recalc, fully best-effort (never blocks the score response).
        from services.messaging_events import emit_score_events
        emit_score_events(foursome, hole_number, scores)

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

    For multi-foursome cup rounds, status flips only when *every*
    foursome has finished — i.e. each foursome has at least one
    non-null gross score on all 18 holes.  This prevents the first
    foursome to finish from locking sibling groups out of scoring.
    Single-foursome rounds (casual play, one-group cup days) flip
    on the first call, same as before.
    """
    def post(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects
                 .select_related('course')
                 .prefetch_related('foursomes__memberships__player'),
            pk=pk,
        )

        all_done = self._all_foursomes_done(round_obj)
        # Single-foursome rounds (casual play, one-group cup days) complete on
        # this explicit user request even with holes unscored — finishing early
        # (a match closed out, or a casual round cut short) is a deliberate action
        # the score-entry soft-gate already warns about, and the only caller is a
        # "Complete Round" / "Finish round" tap.  Multi-foursome rounds still wait
        # for every group so the first to finish can't lock the others out.
        single_foursome = round_obj.foursomes.count() == 1

        if (all_done or single_foursome) and round_obj.status != 'complete':
            round_obj.status = 'complete'
            round_obj.save(update_fields=['status'])
            # Notify followers the multi-group round is final (once; best-effort).
            from services.push import maybe_notify_round_complete
            maybe_notify_round_complete(round_obj)
            from services.messaging_events import emit_round_complete
            emit_round_complete(round_obj)

        # Finalise cup points whenever this is called — partial-round
        # calls still want their group's points reflected on the live
        # leaderboard even before the round flips to complete.
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
            # Surfaces "your group is done, others still playing" to the
            # mobile client so it can show a friendly banner instead of
            # the Final Results banner.
            'all_foursomes_done': all_done,
        })

    @staticmethod
    def _all_foursomes_done(round_obj) -> bool:
        """True when every foursome has at least one non-null gross
        score on every hole it's *expected* to play.  Alt-shot holes only
        have one partner posting, so this counts hole coverage rather than
        per-player completeness — matches the mobile-side check that
        already exempts the dimmed alt-shot partner.

        Mid-round withdrawals shrink the expected set: a hole abandoned at
        the withdrawal (``withdrew_killed_next_hole``) is exempt for the
        whole group, and a hole no remaining player is active for is exempt
        too — so the round can still complete once everyone still playing
        has finished."""
        from scoring.models import HoleScore
        foursomes = list(round_obj.foursomes.prefetch_related('memberships'))
        if not foursomes:
            return False
        for fs in foursomes:
            expected = RoundCompleteView._expected_holes(fs)
            holes = set(
                HoleScore.objects
                .filter(foursome=fs, gross_score__isnull=False)
                .values_list('hole_number', flat=True)
            )
            if expected - holes:
                return False
        return True

    @staticmethod
    def _expected_holes(fs) -> set:
        """Holes a foursome must have a score on to be 'done', accounting
        for mid-round withdrawals (killed holes + game-over holes excluded).

        The base set is the round's holes in play (services/hole_plan) rather
        than a hardcoded 1..18, so a 9-hole / partial / shotgun round completes
        on exactly the holes it plays. (Withdrawal bookkeeping still compares by
        hole number, which matches play order for ascending partial rounds; a
        withdrawal inside a wrapped shotgun order is a rare combined edge case.)
        """
        from services.hole_plan import holes_in_play
        members = list(fs.memberships.all())
        # Holes abandoned at a withdrawal — voided for everyone.
        killed = {
            m.withdrew_after_hole + 1
            for m in members
            if m.withdrew_after_hole is not None
            and m.withdrew_killed_next_hole
            and m.withdrew_after_hole + 1 <= 18
        }
        expected = set()
        for h in holes_in_play(fs.round, fs):
            if h in killed:
                continue
            # At least one member must still be active on this hole.
            if any(m.withdrew_after_hole is None or h <= m.withdrew_after_hole
                   for m in members):
                expected.add(h)
        return expected


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


class FoursomeRemovePlayerView(APIView):
    """
    POST /api/foursomes/{id}/remove-player/    body: {"player_id": int}

    Tournament-director "no-show" tool — drop a player from a foursome
    AT THE TEE BOX (before any scoring), shrinking the group from
    4-player → 3-player or 3-player → 2-player and reconfiguring any
    Triple Cup game on the foursome to match.

    Refused when:
      • The foursome has any HoleScore rows (scoring has begun).
      • The removal would leave the foursome with <2 real players.
      • The removal would push a downstream short-roster foursome
        below its donor-pool floor — the response carries the same
        error format setup uses so the mobile UI can render it
        verbatim, and the tournament director knows exactly what
        backfill move to make next.

    On success the response includes the refreshed Round + foursome
    composition so the mobile client can refresh its dashboard without
    a second round-trip.
    """
    def post(self, request, pk):
        from django.db import transaction
        from scoring.models import HoleScore
        from scoring.phantom import validate_donor_foursomes
        from tournament.models import Foursome, FoursomeMembership
        from core.models import GameType

        player_id = request.data.get('player_id')
        if not isinstance(player_id, int):
            return Response(
                {'detail': 'player_id (int) is required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        foursome = get_object_or_404(
            Foursome.objects.select_related('round')
                .prefetch_related('memberships__player'),
            pk=pk,
        )

        # Locate the membership being removed.  404 keeps the TD honest —
        # silently no-op-ing here would hide UI bugs that send the wrong id.
        membership = (
            foursome.memberships
            .select_related('player')
            .filter(player_id=player_id, player__is_phantom=False)
            .first()
        )
        if membership is None:
            return Response(
                {'detail': f'Player {player_id} is not in foursome '
                           f'{foursome.id} (or is a phantom).'},
                status=status.HTTP_404_NOT_FOUND,
            )

        # Refuse once scoring has started — partial-round removals are
        # a much harder problem (need to retire that player's posted
        # scores from running match-play results) and not in scope.
        if HoleScore.objects.filter(foursome=foursome).exists():
            return Response(
                {'detail': 'Cannot remove a player after scoring has begun. '
                           'Reopen + reset the foursome first, or finish '
                           'the round and adjust afterwards.'},
                status=status.HTTP_409_CONFLICT,
            )

        # New size after removal.
        real_count = sum(
            1 for m in foursome.memberships.all() if not m.player.is_phantom
        )
        new_size = real_count - 1
        if new_size < 2:
            return Response(
                {'detail': '2-player foursomes cannot drop to 1.  The '
                           'tournament directors options are: leave the '
                           'foursome intact (player joins via backfill), '
                           'or delete the foursome.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Pre-flight: if this foursome has a Triple Cup game, removing
        # the lone member of either side would leave us with team1=N,
        # team2=0 (or vice versa) — not a valid TC config.  Catch it
        # here with a friendly message instead of letting
        # _build_match_plan raise deep in the savepoint.  The team
        # rosters come from match 1 (foursome-wide A vs B split).
        try:
            _tc_game = foursome.triple_cup_game
        except Exception:
            _tc_game = None
        if _tc_game is not None:
            _first = _tc_game.matches.order_by('match_number').first()
            _t1_ids: list = []
            _t2_ids: list = []
            if _first is not None:
                _t1 = _first.teams.filter(team_number=1).first()
                _t2 = _first.teams.filter(team_number=2).first()
                if _t1:
                    _t1_ids = list(
                        _t1.players.filter(is_phantom=False)
                        .values_list('id', flat=True))
                if _t2:
                    _t2_ids = list(
                        _t2.players.filter(is_phantom=False)
                        .values_list('id', flat=True))
            _t1_after = [pid for pid in _t1_ids if pid != player_id]
            _t2_after = [pid for pid in _t2_ids if pid != player_id]
            if not _t1_after or not _t2_after:
                empty_side = (
                    'Team 1' if not _t1_after else 'Team 2'
                )
                # Look up the team's TournamentTeam name if available
                # so the message reads more naturally for cup rounds.
                try:
                    cfg = foursome.ryder_cup_foursome_config
                    if not _t1_after and cfg.team1:
                        empty_side = cfg.team1.name
                    elif not _t2_after and cfg.team2:
                        empty_side = cfg.team2.name
                except Exception:
                    pass
                return Response(
                    {'detail': f'Cannot remove {membership.player.name} — '
                               f'they are the only {empty_side} player in '
                               f'this foursome.  Each cup match needs at '
                               f'least one player on each side.  Pick '
                               f'someone from the other team, or remove '
                               f'the whole foursome from the round.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )

        # Pre-flight: simulate the post-removal donor pool and reject if
        # any downstream short-roster group would lose its required
        # priors.  We commit the membership delete first under SAVEPOINT,
        # validate, and rollback on failure.  Cleaner than re-implementing
        # the donor math inline.
        round_obj = foursome.round
        with transaction.atomic():
            sid = transaction.savepoint()
            membership.delete()
            errors = validate_donor_foursomes(round_obj)
            if errors:
                transaction.savepoint_rollback(sid)
                return Response(
                    {'detail': 'Removing this player would break the donor '
                               'pool for another group.',
                     'errors': errors},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            transaction.savepoint_commit(sid)

            # Re-configure any Triple Cup game on this foursome so its
            # match plan matches the new roster.  4→3 brings in the
            # cross-foursome phantom; 3→2 swaps to the F9/B9/Overall
            # Nassau shape.  Other game types (Nassau/Skins/etc.) are
            # left untouched — their scoring is roster-driven and
            # adapts naturally.
            try:
                tc_game = foursome.triple_cup_game
            except Exception:
                tc_game = None
            if tc_game is not None:
                from services.triple_cup import reconfigure_triple_cup
                # Recover the existing team split from match 1 (the
                # foursome-wide A-vs-B layout — fourball for 4/3-player,
                # "Front 9" for 2-player TC), drop the removed player,
                # and let the shared helper rebuild the TC match plan
                # and manage the phantom lifecycle for the new size.
                first_match = tc_game.matches.order_by('match_number').first()
                team1_ids   = []
                team2_ids   = []
                if first_match is not None:
                    t1 = first_match.teams.filter(team_number=1).first()
                    t2 = first_match.teams.filter(team_number=2).first()
                    if t1:
                        team1_ids = list(
                            t1.players.filter(is_phantom=False)
                            .values_list('id', flat=True)
                        )
                    if t2:
                        team2_ids = list(
                            t2.players.filter(is_phantom=False)
                            .values_list('id', flat=True)
                        )
                team1_ids = [pid for pid in team1_ids if pid != player_id]
                team2_ids = [pid for pid in team2_ids if pid != player_id]
                reconfigure_triple_cup(foursome, team1_ids, team2_ids)

        # Return a compact response — mobile re-fetches the round +
        # leaderboard separately rather than parsing a giant payload here.
        return Response({
            'foursome_id'      : foursome.id,
            'removed_player_id': player_id,
            'new_size'         : new_size,
            'group_number'     : foursome.group_number,
        })


class WithdrawPlayerView(APIView):
    """
    POST /api/foursomes/{id}/withdraw-player/
        body: {
            "player_id"     : int,
            "after_hole"    : int,            # last hole they completed (0..17)
            "kill_next_hole": bool,           # group abandoned hole after_hole+1
            "sixes_segment_action": "void"|"solo"   # Sixes only
        }

    Mid-round withdrawal ("can't continue") — the OPPOSITE of remove-player:
    the player and all their posted scores are KEPT; they're simply not
    expected on holes after ``after_hole``.  The rest of the group keeps
    scoring and the round can complete.  See docs/mid-round-withdrawal.md.

    Unlike FoursomeRemovePlayerView this is allowed (in fact intended) once
    scoring has begun.  Auth is the delegated-scoring resolver so the group's
    designated scorer can record a WD from their own account.
    """
    def post(self, request, pk):
        from accounts.scoring_access import foursome_for_scorer

        foursome = foursome_for_scorer(request.user, pk)

        player_id  = request.data.get('player_id')
        after_hole = request.data.get('after_hole')
        kill_next  = bool(request.data.get('kill_next_hole', False))
        sixes_action = request.data.get('sixes_segment_action')

        if not isinstance(player_id, int):
            return Response({'detail': 'player_id (int) is required.'},
                            status=status.HTTP_400_BAD_REQUEST)
        if not isinstance(after_hole, int) or not (0 <= after_hole <= 17):
            return Response(
                {'detail': 'after_hole (int 0..17) is required — the last '
                           'hole the player completed before withdrawing.'},
                status=status.HTTP_400_BAD_REQUEST)
        if sixes_action not in (None, 'void', 'solo'):
            return Response(
                {'detail': "sixes_segment_action must be 'void' or 'solo'."},
                status=status.HTTP_400_BAD_REQUEST)

        membership = (
            foursome.memberships
            .select_related('player')
            .filter(player_id=player_id, player__is_phantom=False)
            .first()
        )
        if membership is None:
            return Response(
                {'detail': f'Player {player_id} is not in foursome '
                           f'{foursome.id} (or is a phantom).'},
                status=status.HTTP_404_NOT_FOUND)

        membership.withdrew_after_hole       = after_hole
        membership.withdrew_killed_next_hole = kill_next
        membership.save(update_fields=['withdrew_after_hole',
                                       'withdrew_killed_next_hole'])

        # Sixes void/solo: apply the TD's per-WD choice to the affected +
        # remaining segments before recalculating.  Defaults to 'void' (the
        # safe choice) if Sixes is active but no action was supplied.
        active_games = (set(foursome.active_games or [])
                        | set(foursome.round.active_games or []))
        if 'sixes' in active_games:
            from services.sixes import apply_withdrawal_to_sixes
            apply_withdrawal_to_sixes(
                foursome, player_id, after_hole,
                action=sixes_action or 'void',
            )

        _recalculate_games(foursome)

        from services.messaging_events import emit_withdrawal
        emit_withdrawal(foursome, membership.player, after_hole,
                        killed_next=kill_next)

        return Response({
            'foursome_id'        : foursome.id,
            'player_id'          : player_id,
            'withdrew_after_hole': after_hole,
            'killed_hole'        : (after_hole + 1) if kill_next
                                   and after_hole + 1 <= 18 else None,
            'group_number'       : foursome.group_number,
        })


class ReinstatePlayerView(APIView):
    """
    POST /api/foursomes/{id}/reinstate-player/   body: {"player_id": int}

    Undo a mistaken withdrawal — clears ``withdrew_after_hole`` and the
    killed-hole flag, and un-voids any Sixes segments that were voided by
    the withdrawal.  Idempotent.
    """
    def post(self, request, pk):
        from accounts.scoring_access import foursome_for_scorer

        foursome  = foursome_for_scorer(request.user, pk)
        player_id = request.data.get('player_id')
        if not isinstance(player_id, int):
            return Response({'detail': 'player_id (int) is required.'},
                            status=status.HTTP_400_BAD_REQUEST)

        membership = (
            foursome.memberships
            .filter(player_id=player_id, player__is_phantom=False)
            .first()
        )
        if membership is None:
            return Response(
                {'detail': f'Player {player_id} is not in foursome {foursome.id}.'},
                status=status.HTTP_404_NOT_FOUND)

        membership.withdrew_after_hole       = None
        membership.withdrew_killed_next_hole = False
        membership.save(update_fields=['withdrew_after_hole',
                                       'withdrew_killed_next_hole'])

        active_games = (set(foursome.active_games or [])
                        | set(foursome.round.active_games or []))
        if 'sixes' in active_games:
            # No withdrawals left → un-void every segment.
            still_out = foursome.memberships.filter(
                withdrew_after_hole__isnull=False).exists()
            if not still_out:
                foursome.sixes_segments.filter(is_void=True).update(is_void=False)

        _recalculate_games(foursome)

        return Response({
            'foursome_id': foursome.id,
            'player_id'  : player_id,
            'reinstated' : True,
        })


class FoursomeSwapPositionView(APIView):
    """
    POST /api/foursomes/{id}/swap-position/
    body: { "target_group_number": int }   (or "other_foursome_id": int)

    Tournament-director "shift the schedule" tool — swaps this
    foursome's tee position (group_number + tee_time) with the
    foursome currently at the target position.  Useful when:
      • A foursome is late: bump them later so the rest of the field
        keeps moving.
      • A short-roster group needs more donor variety: shift it after
        more 4-player groups have teed off.
      • Wizard left groups in the wrong order: rearrange after the
        fact without rebuilding the round.

    Refused when:
      • Either foursome has any HoleScore (scoring has begun).
      • Target position doesn't exist in the round.
      • Post-swap donor pool validation fails (the new order would
        leave a short-roster group without enough full priors).
    """
    def post(self, request, pk):
        from django.db import transaction
        from scoring.models import HoleScore
        from scoring.phantom import validate_donor_foursomes
        from tournament.models import Foursome

        target = request.data.get('target_group_number')
        other_id = request.data.get('other_foursome_id')
        if target is None and other_id is None:
            return Response(
                {'detail': 'Either target_group_number or '
                           'other_foursome_id is required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        this_fs = get_object_or_404(Foursome, pk=pk)
        round_obj = this_fs.round

        if other_id is not None:
            other_fs = get_object_or_404(
                Foursome.objects.filter(round=round_obj),
                pk=other_id,
            )
        else:
            if not isinstance(target, int):
                return Response(
                    {'detail': 'target_group_number must be an int.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            if target == this_fs.group_number:
                return Response(
                    {'detail': 'Foursome is already at that position.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            other_fs = (
                Foursome.objects
                .filter(round=round_obj, group_number=target)
                .first()
            )
            if other_fs is None:
                return Response(
                    {'detail': f'No foursome at group position {target} '
                               f'in this round.'},
                    status=status.HTTP_404_NOT_FOUND,
                )

        if this_fs.pk == other_fs.pk:
            return Response(
                {'detail': 'Cannot swap a foursome with itself.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Pre-play only on both sides — same rule as remove/move.
        if HoleScore.objects.filter(
            foursome__in=[this_fs, other_fs]
        ).exists():
            return Response(
                {'detail': 'Cannot swap positions after scoring has '
                           'begun in either foursome.'},
                status=status.HTTP_409_CONFLICT,
            )

        # Swap group_number + tee_time atomically.  group_number has a
        # unique_together('round','group_number') constraint, so we
        # temporarily park this_fs at a sentinel value to avoid the
        # collision mid-swap.
        with transaction.atomic():
            sid = transaction.savepoint()
            this_gn   = this_fs.group_number
            this_tee  = this_fs.tee_time
            other_gn  = other_fs.group_number
            other_tee = other_fs.tee_time
            # Park at a high sentinel — also guarded against the very
            # unlikely case of an existing group at INT_MAX.
            sentinel = (
                Foursome.objects
                .filter(round=round_obj)
                .order_by('-group_number')
                .values_list('group_number', flat=True)
                .first() or 0
            ) + 1000
            this_fs.group_number = sentinel
            this_fs.save(update_fields=['group_number'])
            other_fs.group_number = this_gn
            other_fs.tee_time     = this_tee
            other_fs.save(update_fields=['group_number', 'tee_time'])
            this_fs.group_number = other_gn
            this_fs.tee_time     = other_tee
            this_fs.save(update_fields=['group_number', 'tee_time'])

            errors = validate_donor_foursomes(round_obj)
            if errors:
                transaction.savepoint_rollback(sid)
                return Response(
                    {'detail': 'Swapping positions would break the '
                               'donor pool for another group.',
                     'errors': errors},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            transaction.savepoint_commit(sid)

        return Response({
            'foursome_id'        : this_fs.id,
            'new_group_number'   : this_fs.group_number,
            'new_tee_time'       : str(this_fs.tee_time)
                                   if this_fs.tee_time else None,
            'swapped_with_id'    : other_fs.id,
            'swapped_with_group' : other_fs.group_number,
        })


class RoundMovePlayerView(APIView):
    """
    POST /api/rounds/{id}/move-player/
    body: {
        "player_id"        : int,
        "from_foursome_id" : int,
        "to_foursome_id"   : int,
    }

    Tournament-director "rebalance at the tee box" tool — move a
    player from one foursome to another before scoring begins.  Both
    foursomes' TC games (if any) reconfigure to match the new
    rosters: A shrinks (4→3 phantom add, 3→2 Nassau swap), B grows
    (3→4 phantom strip, 2→3 phantom add).  The player keeps their
    tee assignment and (in cup mode) their TournamentTeam.

    Refused when:
      • Either foursome has any HoleScore (scoring has begun).
      • From-foursome would drop below 2 real players.
      • To-foursome would exceed 4 real players.
      • Removal would empty a team in from-foursome OR addition
        would push a team in to-foursome above 2 — TC matches need
        a 1–2 / 1–2 split per side.
      • Donor-pool validator rejects the post-move composition.

    On success: 200 with the refreshed group sizes.
    """
    def post(self, request, pk):
        from django.db import transaction
        from scoring.models import HoleScore
        from scoring.phantom import validate_donor_foursomes
        from services.triple_cup import reconfigure_triple_cup
        from tournament.models import (
            Foursome, FoursomeMembership, TournamentTeam,
        )

        player_id        = request.data.get('player_id')
        from_foursome_id = request.data.get('from_foursome_id')
        to_foursome_id   = request.data.get('to_foursome_id')
        if not all(
            isinstance(v, int)
            for v in (player_id, from_foursome_id, to_foursome_id)
        ):
            return Response(
                {'detail': 'player_id, from_foursome_id, '
                           'to_foursome_id are all required (int).'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if from_foursome_id == to_foursome_id:
            return Response(
                {'detail': 'from and to foursomes must be different.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        round_obj = get_object_or_404(Round, pk=pk)
        from_fs = get_object_or_404(
            Foursome.objects
                .filter(round=round_obj)
                .prefetch_related('memberships__player'),
            pk=from_foursome_id,
        )
        to_fs = get_object_or_404(
            Foursome.objects
                .filter(round=round_obj)
                .prefetch_related('memberships__player'),
            pk=to_foursome_id,
        )

        # Player must currently be in from_fs (and be real).
        from_membership = (
            from_fs.memberships
            .select_related('player', 'tee')
            .filter(player_id=player_id, player__is_phantom=False)
            .first()
        )
        if from_membership is None:
            return Response(
                {'detail': f'Player {player_id} is not in foursome '
                           f'{from_fs.group_number} (or is a phantom).'},
                status=status.HTTP_404_NOT_FOUND,
            )

        # Both sides must be pre-play.  Either side having scores
        # already would corrupt match results; refuse rather than try
        # to invent semantics for mid-round roster swaps.
        if HoleScore.objects.filter(
            foursome__in=[from_fs, to_fs]
        ).exists():
            return Response(
                {'detail': 'Cannot move a player after scoring has begun '
                           'in either foursome.  Reopen the round and '
                           'clear scores first, or finish play and '
                           'adjust afterwards.'},
                status=status.HTTP_409_CONFLICT,
            )

        # Size guards.
        from_real_count = sum(
            1 for m in from_fs.memberships.all() if not m.player.is_phantom
        )
        to_real_count = sum(
            1 for m in to_fs.memberships.all() if not m.player.is_phantom
        )
        if from_real_count - 1 < 2:
            return Response(
                {'detail': f'Cannot remove from group '
                           f'{from_fs.group_number} — it would drop below '
                           f'2 players.  Move another player out of a '
                           f'larger group first.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if to_real_count + 1 > 4:
            return Response(
                {'detail': f'Cannot add to group {to_fs.group_number} — '
                           f'it already has 4 players.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Compute post-move TC team rosters for both foursomes (only
        # for TC games — Nassau/Skins/etc. adapt naturally to roster
        # changes without a reconfig step).
        def _read_tc_teams(fs):
            try:
                tc = fs.triple_cup_game
            except Exception:
                return None
            first = tc.matches.order_by('match_number').first()
            if first is None:
                return [], []
            t1 = first.teams.filter(team_number=1).first()
            t2 = first.teams.filter(team_number=2).first()
            t1_ids = list(t1.players.filter(is_phantom=False)
                          .values_list('id', flat=True)) if t1 else []
            t2_ids = list(t2.players.filter(is_phantom=False)
                          .values_list('id', flat=True)) if t2 else []
            return t1_ids, t2_ids

        from_tc = _read_tc_teams(from_fs)
        to_tc   = _read_tc_teams(to_fs)

        # Determine which team the moving player belongs to.  In cup
        # mode this is fixed by their TournamentTeam.  In casual mode
        # the from-side's TC team membership is the source of truth.
        moving_on_team = None
        if from_tc is not None:
            f_t1, f_t2 = from_tc
            if player_id in f_t1:
                moving_on_team = 1
            elif player_id in f_t2:
                moving_on_team = 2

        # Build post-move rosters.
        if from_tc is not None:
            f_t1_after = [pid for pid in from_tc[0] if pid != player_id]
            f_t2_after = [pid for pid in from_tc[1] if pid != player_id]
            if not f_t1_after or not f_t2_after:
                empty_side = 'Team 1' if not f_t1_after else 'Team 2'
                try:
                    cfg = from_fs.ryder_cup_foursome_config
                    if not f_t1_after and cfg.team1:
                        empty_side = cfg.team1.name
                    elif not f_t2_after and cfg.team2:
                        empty_side = cfg.team2.name
                except Exception:
                    pass
                return Response(
                    {'detail': f'Cannot move {from_membership.player.name} — '
                               f'they are the only {empty_side} player in '
                               f'group {from_fs.group_number}.  Each cup '
                               f'match needs at least one player on each '
                               f'side.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
        else:
            f_t1_after = f_t2_after = None

        if to_tc is not None:
            t_t1_after = list(to_tc[0])
            t_t2_after = list(to_tc[1])
            # Place the moving player on the matching team if known;
            # for cup mode also consult the to-foursome's TournamentTeam
            # config so the player lands on the right side even if
            # the to-foursome currently has no team1 or team2 members.
            target_team = moving_on_team
            if target_team is None:
                # Look up the player's TournamentTeam against the
                # to-foursome's cup config.
                try:
                    cfg = to_fs.ryder_cup_foursome_config
                    if cfg.team1 and cfg.team1.players.filter(
                        pk=player_id
                    ).exists():
                        target_team = 1
                    elif cfg.team2 and cfg.team2.players.filter(
                        pk=player_id
                    ).exists():
                        target_team = 2
                except Exception:
                    pass
            if target_team is None:
                # Casual mode + no signal from from-side either —
                # default to whichever side has fewer players.
                target_team = 1 if len(t_t1_after) <= len(t_t2_after) else 2
            if target_team == 1:
                t_t1_after.append(player_id)
            else:
                t_t2_after.append(player_id)
            if len(t_t1_after) > 2 or len(t_t2_after) > 2:
                full_side = (
                    'Team 1' if len(t_t1_after) > 2 else 'Team 2'
                )
                try:
                    cfg = to_fs.ryder_cup_foursome_config
                    if len(t_t1_after) > 2 and cfg.team1:
                        full_side = cfg.team1.name
                    elif len(t_t2_after) > 2 and cfg.team2:
                        full_side = cfg.team2.name
                except Exception:
                    pass
                return Response(
                    {'detail': f'Cannot add {from_membership.player.name} '
                               f'to group {to_fs.group_number} — '
                               f'{full_side} would have 3 players (cup '
                               f'matches cap each side at 2).'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
        else:
            t_t1_after = t_t2_after = None

        # All checks passed — perform the move atomically.
        with transaction.atomic():
            sid = transaction.savepoint()
            # Move the membership: same player + tee, new foursome.
            # Preserve handicap values — the player's course/playing
            # handicap is per-tee, and we're not changing tees.
            from_tee              = from_membership.tee
            course_hcp            = from_membership.course_handicap
            playing_hcp           = from_membership.playing_handicap
            from_membership.delete()
            FoursomeMembership.objects.create(
                foursome         = to_fs,
                player_id        = player_id,
                tee              = from_tee,
                course_handicap  = course_hcp,
                playing_handicap = playing_hcp,
            )

            errors = validate_donor_foursomes(round_obj)
            if errors:
                transaction.savepoint_rollback(sid)
                return Response(
                    {'detail': 'Moving this player would break the donor '
                               'pool for another group.',
                     'errors': errors},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            transaction.savepoint_commit(sid)

            # Reconfigure TC on both foursomes if they had a TC game.
            if from_tc is not None:
                reconfigure_triple_cup(from_fs, f_t1_after, f_t2_after)
            if to_tc is not None:
                reconfigure_triple_cup(to_fs, t_t1_after, t_t2_after)

        return Response({
            'player_id'       : player_id,
            'from_foursome_id': from_fs.id,
            'to_foursome_id'  : to_fs.id,
            'from_new_size'   : from_real_count - 1,
            'to_new_size'     : to_real_count + 1,
        })


# ---------------------------------------------------------------------------
# Leaderboard
# ---------------------------------------------------------------------------

class LeaderboardView(APIView):
    def get(self, request, pk):
        # Own-account, a designated scorer, OR a phone-matched participant
        # (preserves Friends Phase 2a "Shared with me"). Closes the prior
        # open-by-id read.
        round_obj = round_for_reader(
            request.user, pk,
            base=Round.objects.select_related('course', 'tournament')
                    .prefetch_related('foursomes'),
        )
        t          = round_obj.tournament
        # Cup competitions store their display name on the TeamTournament
        # row (e.g. "ETC Cup"); fall back to None when this tournament
        # isn't running a cup, so the client can choose how to display.
        cup_name = None
        if t is not None:
            tt = getattr(t, 'team_tournament', None)
            if tt is not None:
                cup_name = tt.cup_name
        lb_games   = _build_leaderboard(round_obj)
        is_cup_rnd = hasattr(round_obj, 'ryder_cup_config')
        return Response({
            'round_id'              : round_obj.id,
            'round_date'            : str(round_obj.date),
            'course'                : str(round_obj.course),
            'status'                : round_obj.status,
            # The owning account — lets the app flag a cross-account (support /
            # shared) read-only view without trusting how the round was opened.
            'account_id'            : round_obj.account_id,
            'account_name'          : getattr(round_obj.account, 'name', ''),
            'is_cup_round'          : is_cup_rnd,
            'active_games'          : _leaderboard_active_games(round_obj, lb_games),
            'tournament_id'         : t.id   if t else None,
            'tournament_name'       : t.name if t else None,
            'cup_name'              : cup_name,
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
        foursome = foursome_for_scorer(request.user, pk)
        ser = NassauSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.nassau import setup_nassau, calculate_nassau, nassau_summary
        # Which match this is: a team Nassau (default), a Singles Match, or a
        # Nassau Nine.  A foursome can hold one of each at once, so setup only
        # replaces the SAME game_type.
        single_match = d.get('single_match', False)
        game_type = d.get('game_type') or ('nassau_nine' if single_match else 'nassau')
        setup_nassau(
            foursome,
            team1_ids     = d['team1_player_ids'],
            team2_ids     = d['team2_player_ids'],
            handicap_mode = d.get('handicap_mode', 'net'),
            net_percent   = d.get('net_percent', 100),
            press_mode    = d.get('press_mode', 'none'),
            press_unit    = d.get('press_unit', '0.00'),
            variant       = d.get('variant', 'none'),
            play_front    = d.get('play_front', True),
            play_back     = d.get('play_back', True),
            play_overall  = d.get('play_overall', True),
            single_match  = single_match,
            loss_cap      = d.get('loss_cap'),
            game_type     = game_type,
        )
        calculate_nassau(foursome, game_type)
        return Response(nassau_summary(foursome, game_type), status=status.HTTP_201_CREATED)


class NassauPressView(APIView):
    """
    POST /api/foursomes/{id}/nassau/press/
    Body: { "start_hole": 7 }

    Called by the losing team to declare a manual press.  The winning
    team always accepts — no pending/rejection state needed.
    Returns the updated nassau summary.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        ser = NassauPressSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.nassau import (add_manual_press, nassau_summary,
                                      resolve_nassau_game_type)
        start_hole = ser.validated_data['start_hole']
        game_type  = resolve_nassau_game_type(
            foursome, ser.validated_data.get('game_type'))
        try:
            add_manual_press(foursome, start_hole, game_type=game_type)
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=status.HTTP_400_BAD_REQUEST)

        # Announce the new press to the round feed (best-effort — never blocks).
        from services.messaging_events import emit_nassau_press_called
        emit_nassau_press_called(foursome, start_hole, game_type=game_type)

        return Response(nassau_summary(foursome, game_type))


class NassauResultView(APIView):
    """
    GET /api/foursomes/{id}/nassau/?game=<nassau|match_18|nassau_nine>

    `game` selects which of the foursome's Nassau-family matches to return
    (defaults to the team Nassau).  Legacy clients omit it → 'nassau'.
    """
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from services.nassau import nassau_summary
        # None → the resolver picks the foursome's primary Nassau match, so a
        # legacy client with no ?game still resolves a Nassau-Nine-only round.
        game_type = request.query_params.get('game')
        summary = nassau_summary(foursome, game_type)
        if summary is None:
            return Response(
                {'detail': 'No Nassau game set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


# ---------------------------------------------------------------------------
# Sixes
# ---------------------------------------------------------------------------

class SixesSetupView(APIView):
    """
    POST /api/foursomes/{id}/sixes/setup/
    Body: { "segments": [{...}, ...] }
    See services/sixes.py for segment dict format.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        ser = SixesSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.sixes import setup_sixes
        data     = ser.validated_data
        segments = setup_sixes(
            foursome,
            data['segments'],
            handicap_mode       = data.get('handicap_mode', 'net'),
            net_percent         = data.get('net_percent', 100),
            scoring_format      = data.get('scoring_format', 'classic'),
            handicap_allocation = data.get('handicap_allocation', 'per_segment'),
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
        foursome = foursome_for_scorer(request.user, pk)
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
        foursome = foursome_for_scorer(request.user, pk)
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
        foursome = foursome_for_scorer(request.user, pk)
        ser = Points531SetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.points_531 import (
            setup_points_531, calculate_points_531, points_531_summary,
        )
        data = ser.validated_data
        setup_points_531(
            foursome,
            handicap_mode  = data.get('handicap_mode', 'net'),
            net_percent    = data.get('net_percent', 100),
            loss_cap       = data.get('loss_cap'),
            payout_style   = data.get('payout_style', 'per_point'),
            per_point_mode = data.get('per_point_mode', 'average'),
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
        foursome = foursome_for_scorer(request.user, pk)
        from services.points_531 import points_531_summary
        return Response(points_531_summary(foursome))


# ---------------------------------------------------------------------------
# Honors (side-game-only carry-token points game)
# ---------------------------------------------------------------------------

class HonorsSetupView(APIView):
    """
    POST /api/foursomes/{id}/honors/setup/
    Body: { "handicap_mode": "net" | "gross" | "strokes_off",
            "net_percent":  0..200, "loss_cap": null|number,
            "payout_style": "pool"|"per_point",
            "per_point_mode": "average"|"all"|"first" }

    Creates (or replaces) the HonorsGame for this foursome, then re-runs
    calculate_honors so any hole scores already on file are reflected in
    the first summary the UI fetches.  Both are idempotent.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        ser = HonorsSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.honors import (
            setup_honors, calculate_honors, honors_summary,
        )
        data = ser.validated_data
        setup_honors(
            foursome,
            handicap_mode  = data.get('handicap_mode', 'net'),
            net_percent    = data.get('net_percent', 100),
            loss_cap       = data.get('loss_cap'),
            payout_style   = data.get('payout_style', 'per_point'),
            per_point_mode = data.get('per_point_mode', 'average'),
            participant_player_ids = data.get('participant_player_ids', []),
        )
        calculate_honors(foursome)
        return Response(
            honors_summary(foursome),
            status=status.HTTP_201_CREATED,
        )


class HonorsResultView(APIView):
    """GET /api/foursomes/{id}/honors/"""
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from services.honors import honors_summary
        return Response(honors_summary(foursome))


# ---------------------------------------------------------------------------
# Las Vegas
# ---------------------------------------------------------------------------

class VegasSetupView(APIView):
    """
    POST /api/foursomes/{id}/vegas/setup/
    Body: handicap_mode, net_percent, net_max_double_bogey, birdie_mode
    ('flip'|'multiplier'), carryover, loss_cap, team1_player_ids[2],
    team2_player_ids[2]. Idempotent; recalcs any scores already on file.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        ser = VegasSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.vegas import setup_vegas, calculate_vegas, vegas_summary
        setup_vegas(
            foursome,
            team1_ids            = d['team1_player_ids'],
            team2_ids            = d['team2_player_ids'],
            handicap_mode        = d.get('handicap_mode', 'net'),
            net_percent          = d.get('net_percent', 100),
            net_max_double_bogey = d.get('net_max_double_bogey', True),
            birdie_mode          = d.get('birdie_mode', 'flip'),
            carryover            = d.get('carryover', False),
            loss_cap             = d.get('loss_cap'),
        )
        calculate_vegas(foursome)
        return Response(vegas_summary(foursome), status=status.HTTP_201_CREATED)


class VegasResultView(APIView):
    """GET /api/foursomes/{id}/vegas/"""
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from services.vegas import vegas_summary
        return Response(vegas_summary(foursome))


# ---------------------------------------------------------------------------
# Fourball (2v2 best-ball match play)
# ---------------------------------------------------------------------------

class FourballSetupView(APIView):
    """
    POST /api/foursomes/{id}/fourball/setup/
    Body: team1_player_ids[2], team2_player_ids[2], handicap_mode
    ('net'|'gross'|'strokes_off'), net_percent, bet_amount?. Idempotent;
    recalcs any scores already on file and returns the summary.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        ser = FourballSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.fourball import (
            setup_fourball, calculate_fourball, fourball_summary,
        )
        try:
            setup_fourball(
                foursome,
                team1_ids     = d['team1_player_ids'],
                team2_ids     = d['team2_player_ids'],
                handicap_mode = d.get('handicap_mode', 'net'),
                net_percent   = d.get('net_percent', 100),
                bet_amount    = d.get('bet_amount'),
            )
        except ValueError as exc:
            return Response({'detail': str(exc)},
                            status=status.HTTP_400_BAD_REQUEST)
        calculate_fourball(foursome)
        return Response(fourball_summary(foursome),
                        status=status.HTTP_201_CREATED)


class FourballResultView(APIView):
    """GET /api/foursomes/{id}/fourball/"""
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from services.fourball import fourball_summary
        summary = fourball_summary(foursome)
        if summary is None:
            return Response(
                {'detail': 'No Fourball game set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


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
        foursome = foursome_for_scorer(request.user, pk)
        from api.serializers import SkinsSetupSerializer
        ser = SkinsSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.skins import setup_skins, calculate_skins, skins_summary
        d = ser.validated_data
        setup_skins(
            foursome,
            handicap_mode  = d.get('handicap_mode', 'net'),
            net_percent    = d.get('net_percent', 100),
            carryover      = d.get('carryover', True),
            allow_junk     = d.get('allow_junk', False),
            payout_style   = d.get('payout_style', 'pool'),
            per_point_mode = d.get('per_point_mode', 'first'),
            per_point_rate = d.get('per_point_rate', 0),
            loss_cap       = d.get('loss_cap'),
            participant_player_ids = d.get('participant_player_ids', []),
        )
        calculate_skins(foursome)
        return Response(skins_summary(foursome), status=status.HTTP_201_CREATED)


class SkinsResultView(APIView):
    """GET /api/foursomes/{id}/skins/"""
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
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
        foursome = foursome_for_scorer(request.user, pk)
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
# Spots (capture add-on — separate pot, tallied like junk)
# ---------------------------------------------------------------------------

class SpotsSetupView(APIView):
    """
    POST /api/foursomes/{id}/spots/setup/
    Body: {"bet_unit": "1.00"?, "payout_style": "pay_around"|"pool"}
    Creates (or replaces) the SpotsGame. Safe to call repeatedly.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from api.serializers import SpotsSetupSerializer
        ser = SpotsSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        from services.spots import setup_spots, spots_summary
        d = ser.validated_data
        setup_spots(
            foursome,
            bet_unit       = d.get('bet_unit'),
            payout_style   = d.get('payout_style', 'per_point'),
            per_point_mode = d.get('per_point_mode', 'all'),
            loss_cap       = d.get('loss_cap'),
        )
        return Response(spots_summary(foursome), status=status.HTTP_201_CREATED)


class SpotsResultView(APIView):
    """GET /api/foursomes/{id}/spots/"""
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from services.spots import spots_summary
        return Response(spots_summary(foursome))


class SpotsTallyView(APIView):
    """
    POST /api/foursomes/{id}/spots/tally/
    Body: {"hole_number": 1..18, "entries": [{"player_id": N, "count": N}, ...]}
    Upserts per-player spot counts for a hole (count=0 deletes the row).
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from api.serializers import SpotsTallySerializer
        ser = SpotsTallySerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        # No pre-check for an existing SpotsGame: tally_spots auto-creates it with
        # defaults on the first tally, so recording a spot on a Spots side game
        # that was added but never explicitly configured just works (the hub's
        # "Edit Spots" tunes stake/payout later).
        from services.spots import tally_spots, spots_summary
        tally_spots(
            foursome,
            hole_number=ser.validated_data['hole_number'],
            entries=ser.validated_data['entries'],
        )
        return Response(spots_summary(foursome))


# ---------------------------------------------------------------------------
# Wolf
# ---------------------------------------------------------------------------

class WolfSetupView(APIView):
    """
    POST /api/foursomes/{id}/wolf/setup/
    Body: {
        "handicap_mode": "net"|"gross"|"strokes_off", "net_percent": 0..200,
        "wolf_order": [player_id, ...],
        "lone_wolf_points": 3, "blind_wolf_points": 6, "team_win_points": 1,
        "wolf_loses_ties": false, "non_wolf_bonus": false,
        "last_place_wolf_1718": true
    }

    Creates (or replaces) the Wolf game, then runs calculate_wolf so any
    scores/decisions already on file are reflected in the first summary.
    Idempotent.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from api.serializers import WolfSetupSerializer
        ser = WolfSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.wolf import setup_wolf, calculate_wolf, wolf_summary
        setup_wolf(
            foursome,
            handicap_mode        = d.get('handicap_mode', 'net'),
            net_percent          = d.get('net_percent', 100),
            wolf_order           = d.get('wolf_order') or [],
            lone_wolf_points     = d.get('lone_wolf_points', 3),
            blind_wolf_points    = d.get('blind_wolf_points', 6),
            team_win_points      = d.get('team_win_points', 1),
            wolf_loses_ties       = d.get('wolf_loses_ties', False),
            non_wolf_bonus        = d.get('non_wolf_bonus', False),
            last_place_wolf_1718  = d.get('last_place_wolf_1718', True),
            require_lone_or_blind = d.get('require_lone_or_blind', False),
            loss_cap              = d.get('loss_cap'),
        )
        calculate_wolf(foursome)
        return Response(wolf_summary(foursome), status=status.HTTP_201_CREATED)


class WolfResultView(APIView):
    """GET /api/foursomes/{id}/wolf/"""
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from services.wolf import wolf_summary
        return Response(wolf_summary(foursome))


class WolfOrderView(APIView):
    """
    POST /api/foursomes/{id}/wolf/order/
    Body: { "wolf_order": [player_id, ...] }

    Updates only the rotation order (decisions/results survive).  Returns
    the refreshed summary.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from api.serializers import WolfOrderSerializer
        ser = WolfOrderSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from games.models import WolfGame
        try:
            foursome.wolf_game
        except WolfGame.DoesNotExist:
            return Response(
                {'detail': 'Wolf game not set up for this foursome.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        from services.wolf import (
            set_wolf_order, wolf_summary, WolfOrderLocked,
        )
        try:
            set_wolf_order(foursome, ser.validated_data['wolf_order'])
        except WolfOrderLocked as e:
            return Response(
                {'detail': e.message},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(wolf_summary(foursome))


class WolfDecisionView(APIView):
    """
    POST /api/foursomes/{id}/wolf/decision/
    Body: { "hole_number": 1..18, "decision": "partner"|"lone"|"blind"|"pending",
            "partner_id": <player_id, only for 'partner'> }

    Upserts the Wolf's decision for a hole, re-runs calculate_wolf, and
    returns the refreshed summary.  'pending' clears a previously-set
    decision.  A partner pick is validated against the resolved Wolf for
    that hole (must be a different real player; 4-player games only).
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from api.serializers import WolfDecisionSerializer
        ser = WolfDecisionSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from games.models import WolfGame, WolfHoleDecision
        try:
            game = foursome.wolf_game
        except WolfGame.DoesNotExist:
            return Response(
                {'detail': 'Wolf game not set up for this foursome.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        hole      = d['hole_number']
        decision  = d['decision']
        partner_id = d.get('partner_id')

        from services.wolf import (
            resolve_wolf_for_hole, partner_locked_for_hole,
            calculate_wolf, wolf_summary, _real_members,
        )
        real_ids = [m.player_id for m in _real_members(foursome)]

        if decision == 'partner':
            if len(real_ids) != 4:
                return Response(
                    {'detail': 'Partner picks are only allowed in 4-player Wolf.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            wolf = resolve_wolf_for_hole(foursome, hole)
            if partner_id not in real_ids or partner_id == wolf:
                return Response(
                    {'detail': 'Partner must be a real player other than the Wolf.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            if partner_locked_for_hole(foursome, hole):
                return Response(
                    {'detail': 'This is the Wolf’s last turn in the first 16 holes '
                               'and they must go Lone or Blind.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )

        if decision == 'pending':
            WolfHoleDecision.objects.filter(game=game, hole_number=hole).delete()
        else:
            WolfHoleDecision.objects.update_or_create(
                game=game, hole_number=hole,
                defaults={
                    'decision'  : decision,
                    'partner_id': partner_id if decision == 'partner' else None,
                },
            )

        calculate_wolf(foursome)
        return Response(wolf_summary(foursome))


# ---------------------------------------------------------------------------
# Rabbit
# ---------------------------------------------------------------------------

class RabbitSetupView(APIView):
    """
    POST /api/foursomes/{id}/rabbit/setup/
    Body: { "handicap_mode": "net"|"gross"|"strokes_off", "net_percent": 0..200,
            "accumulate": true|false, "num_segments": 1|2|3 }

    Creates (or replaces) the Rabbit game, then runs calculate_rabbit so any
    scores already on file are reflected in the first summary.  Idempotent.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from api.serializers import RabbitSetupSerializer
        ser = RabbitSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.rabbit import setup_rabbit, calculate_rabbit, rabbit_summary
        setup_rabbit(
            foursome,
            handicap_mode = d.get('handicap_mode', 'net'),
            net_percent   = d.get('net_percent', 100),
            accumulate    = d.get('accumulate', True),
            num_segments  = d.get('num_segments', 1),
        )
        calculate_rabbit(foursome)
        return Response(rabbit_summary(foursome), status=status.HTTP_201_CREATED)


class RabbitResultView(APIView):
    """GET /api/foursomes/{id}/rabbit/"""
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from services.rabbit import rabbit_summary
        return Response(rabbit_summary(foursome))


# ---------------------------------------------------------------------------
# Triple Cup (One-Round Ryder Cup)
# ---------------------------------------------------------------------------

class TripleCupSetupView(APIView):
    """
    POST /api/foursomes/{id}/triple-cup/setup/
    Body: {
        "team1_player_ids": [pk, ...],   # 1 or 2 entries
        "team2_player_ids": [pk, ...],   # 1 or 2 entries
        "handicap_mode":      "net" | "gross" | "strokes_off",
        "net_percent":        0..200,
        "alt_shot_low_pct":   0..100,    # default 50 (USGA)
        "alt_shot_high_pct":  0..100,    # default 50 (USGA)
        "phantom_score_mode": "net_par" | "net_bogey"
    }

    Creates (or replaces) the TripleCupGame for this foursome and re-runs
    calculate_triple_cup so the first summary the UI fetches already
    reflects any hole scores already on file.
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from api.serializers import TripleCupSetupSerializer
        ser = TripleCupSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.triple_cup import (
            setup_triple_cup, calculate_triple_cup, triple_cup_summary,
        )
        try:
            setup_triple_cup(
                foursome,
                team1_ids                  = d['team1_player_ids'],
                team2_ids                  = d['team2_player_ids'],
                handicap_mode              = d.get('handicap_mode', 'net'),
                net_percent                = d.get('net_percent', 100),
                alt_shot_low_pct           = d.get('alt_shot_low_pct', 50),
                alt_shot_high_pct          = d.get('alt_shot_high_pct', 50),
                foursomes_first            = d.get('foursomes_first', False),
                foursomes_team1_first_tee  = d.get('foursomes_team1_first_tee'),
                foursomes_team2_first_tee  = d.get('foursomes_team2_first_tee'),
            )
        except ValueError as exc:
            return Response({'detail': str(exc)},
                            status=status.HTTP_400_BAD_REQUEST)
        calculate_triple_cup(foursome)
        return Response(triple_cup_summary(foursome),
                        status=status.HTTP_201_CREATED)


class TripleCupResultView(APIView):
    """GET /api/foursomes/{id}/triple-cup/"""
    def get(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from services.triple_cup import triple_cup_summary
        summary = triple_cup_summary(foursome)
        if summary is None:
            return Response(
                {'detail': 'No Triple Cup game set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


class TripleCupFoursomesTeeOffView(APIView):
    """
    POST /api/foursomes/{id}/triple-cup/foursomes-tee-off/
    Body: { "team1_first_tee": <player_id|null>,
            "team2_first_tee": <player_id|null> }

    Sets (or clears) the alt-shot first-tee-off player on the
    foursomes match.  Used by the score-entry prompt that fires on
    hole 7 when the team hasn't decided yet — which is the cup
    convention (matches set in advance, tee-off decided on the
    first alt-shot hole).
    """
    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
        from games.models import TripleCupGame, TripleCupMatch

        try:
            game = foursome.triple_cup_game
        except TripleCupGame.DoesNotExist:
            return Response(
                {'detail': 'No Triple Cup game set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )

        try:
            match = game.matches.get(segment='foursomes')
        except TripleCupMatch.DoesNotExist:
            return Response(
                {'detail': 'This Triple Cup game has no foursomes segment.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Validate each requested first-tee player is actually on the
        # matching side of the foursomes match.
        def _validate(team_num, requested):
            if requested is None:
                return None
            team = match.teams.filter(team_number=team_num).first()
            allowed = set(team.players.values_list('id', flat=True)) if team else set()
            if requested not in allowed:
                raise ValueError(
                    f'Player {requested} is not on team{team_num} of '
                    f'the foursomes match.'
                )
            return requested

        try:
            t1 = _validate(1, request.data.get('team1_first_tee'))
            t2 = _validate(2, request.data.get('team2_first_tee'))
        except ValueError as exc:
            return Response({'detail': str(exc)},
                            status=status.HTTP_400_BAD_REQUEST)

        if 'team1_first_tee' in request.data:
            match.team1_first_tee_player_id = t1
        if 'team2_first_tee' in request.data:
            match.team2_first_tee_player_id = t2
        match.save(update_fields=[
            'team1_first_tee_player', 'team2_first_tee_player',
        ])

        # Recalculate doesn't depend on tee-off (scoring uses
        # min-of-team-grosses regardless), but refreshing keeps the
        # summary's hole-by-hole player view consistent if any scores
        # already exist.
        from services.triple_cup import calculate_triple_cup, triple_cup_summary
        calculate_triple_cup(foursome)
        return Response(triple_cup_summary(foursome))


# ---------------------------------------------------------------------------
# Multi-Foursome Skins (Round-scoped)
# ---------------------------------------------------------------------------

class MultiSkinsSetupView(APIView):
    """
    POST /api/rounds/{pk}/multi-skins/setup/
    Body: {
        "handicap_mode":   "net" | "gross" | "strokes_off",
        "net_percent":     0..200,
        "bet_unit":        "10.00",          (optional)
        "participant_ids": [12, 13, 17, ...] (>= 2 player IDs in this round)
    }

    Replaces any existing Multi-Skins game on the round.  Also adds
    'multi_skins' to round.active_games so the calculator fires on
    subsequent score submissions.
    """
    def post(self, request, pk):
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
        from api.serializers import MultiSkinsSetupSerializer
        ser = MultiSkinsSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from services.multi_skins import (
            setup_multi_skins, calculate_multi_skins, multi_skins_summary,
            not_on_app_ids,
        )
        # Roster is Halved-members-only: a cross-round pool matches players by
        # phone identity, so a login-less golfer can't participate. Reject them
        # at the boundary (docs/multi-skins-cross-round.md).
        bad = not_on_app_ids(d['participant_ids'])
        if bad:
            return Response(
                {'detail': 'Everyone in a Multi-Group Skins pool must be on '
                           'Halved (a login-less golfer can\'t be matched '
                           'across rounds). Invite them, then add them.',
                 'not_on_app_ids': bad},
                status=status.HTTP_400_BAD_REQUEST)
        setup_multi_skins(
            round_obj,
            participant_ids = d['participant_ids'],
            handicap_mode   = d.get('handicap_mode', 'net'),
            net_percent     = d.get('net_percent', 100),
            bet_unit        = d.get('bet_unit'),
        )
        active = list(round_obj.active_games or [])
        if 'multi_skins' not in active:
            active.append('multi_skins')
            round_obj.active_games = active
            round_obj.save(update_fields=['active_games'])
        calculate_multi_skins(round_obj)
        return Response(multi_skins_summary(round_obj),
                        status=status.HTTP_201_CREATED)


class MultiSkinsResultView(APIView):
    """GET /api/rounds/{pk}/multi-skins/"""
    def get(self, request, pk):
        round_obj = round_for_reader(request.user, pk)
        from services.multi_skins import multi_skins_summary
        return Response(multi_skins_summary(round_obj))


# ---------------------------------------------------------------------------
# Cross-round Multi-Group Skins pool (docs/multi-skins-cross-round.md)
# The pool is hosted on a round's MultiSkinsGame; other rounds LINK into it by
# pasting the host round's /watch/<token>/ spectator link.  Token possession
# grants access (not account-scoped) — the join record is the read grant.
# ---------------------------------------------------------------------------

def _same_course(round_a, round_b) -> bool:
    """True if two rounds are on the same real-world course.  Same account →
    same Course row; cross-account → the account clones share a golf_api_id
    (copy-on-add keeps that catalog identity).  Manual (non-catalog) courses
    only match within an account."""
    if round_a.course_id == round_b.course_id:
        return True
    ga = round_a.course.golf_api_id
    gb = round_b.course.golf_api_id
    return bool(ga) and ga == gb


def _pool_by_token(token):
    """Resolve the host round + its MultiSkinsGame from a watch token, or 404
    (also 404 if the round exists but hosts no pool)."""
    from django.http import Http404
    from games.models import MultiSkinsGame
    round_obj = Round.objects.filter(watch_token=token).first()
    if round_obj is None:
        raise Http404('No such pool.')
    try:
        game = round_obj.multi_skins_game
    except MultiSkinsGame.DoesNotExist:
        raise Http404('That round is not a Multi-Group Skins pool.')
    return round_obj, game


class SkinsPoolResolveView(APIView):
    """GET /api/skins-pool/<token>/ — resolve a pool by the host round's watch
    token.  Optional ?round_id= previews the overlap a link would bring in."""
    permission_classes = [IsAuthenticated]

    def get(self, request, token):
        from services.multi_skins import _summary_for_game, pool_overlap
        host_round, game = _pool_by_token(token)

        overlap_ids = None
        rid = request.query_params.get('round_id')
        if rid:
            mine = account_get_or_404(Round, request.user.account, pk=rid)
            overlap_ids = pool_overlap(game, mine)

        roster = [
            {'player_id': p.id, 'name': p.name, 'short_name': p.short_name}
            for p in game.participants.all()
        ]
        return Response({
            'host_round_id'   : host_round.id,
            'course'          : {'id': host_round.course_id,
                                 'name': host_round.course.name},
            'bet_unit'        : float(game.bet_unit),
            'handicap'        : {'mode': game.handicap_mode,
                                 'net_percent': game.net_percent},
            'roster'          : roster,
            'linked_round_ids': [lr.round_id for lr in game.linked_rounds.all()],
            'overlap_ids'     : overlap_ids,
            'summary'         : _summary_for_game(game),
        })


class SkinsPoolJoinView(APIView):
    """POST /api/skins-pool/<token>/join/  body {round_id}
    Link one of MY rounds into the pool.  Enforces same-course + ≥1 overlap."""
    permission_classes = [IsAuthenticated]

    def post(self, request, token):
        from games.models import MultiSkinsLinkedRound
        from services.multi_skins import (
            pool_overlap, recalc_pools_for_round, reconcile_pool_seating,
            _summary_for_game,
        )
        host_round, game = _pool_by_token(token)

        rid = request.data.get('round_id')
        if not rid:
            return Response({'detail': 'round_id is required.'},
                            status=status.HTTP_400_BAD_REQUEST)
        mine = account_get_or_404(Round, request.user.account, pk=rid)

        if mine.id == host_round.id:
            return Response(
                {'detail': 'That round already hosts this pool.'},
                status=status.HTTP_400_BAD_REQUEST)
        if not _same_course(mine, host_round):
            return Response(
                {'detail': 'A linked round must be on the same course as the '
                           'pool.',
                 'pool_course': host_round.course.name,
                 'round_course': mine.course.name},
                status=status.HTTP_400_BAD_REQUEST)

        overlap = pool_overlap(game, mine)
        if not overlap:
            return Response(
                {'detail': 'None of this round\'s players are in the pool.'},
                status=status.HTTP_400_BAD_REQUEST)

        MultiSkinsLinkedRound.objects.get_or_create(
            game=game, round=mine,
            defaults={'linked_by': getattr(request.user, 'player_profile', None)},
        )
        # The overlapping players now play in the linked round — drop the solo
        # groups the pool auto-made for them in the host round.
        reconcile_pool_seating(game)
        recalc_pools_for_round(mine)
        return Response({'overlap_ids': overlap,
                         'summary': _summary_for_game(game)},
                        status=status.HTTP_201_CREATED)


class SkinsPoolUnlinkView(APIView):
    """POST /api/skins-pool/<token>/unlink/  body {round_id}"""
    permission_classes = [IsAuthenticated]

    def post(self, request, token):
        from games.models import MultiSkinsLinkedRound
        from services.multi_skins import (
            _calculate_game, reconcile_pool_seating, _summary_for_game,
        )
        _host, game = _pool_by_token(token)

        rid = request.data.get('round_id')
        mine = account_get_or_404(Round, request.user.account, pk=rid)
        MultiSkinsLinkedRound.objects.filter(game=game, round=mine).delete()
        # Participants who were only in that round now have nowhere to score —
        # re-seat them in a host solo group.
        reconcile_pool_seating(game)
        _calculate_game(game)
        return Response({'summary': _summary_for_game(game)})


class SkinsPoolMineView(APIView):
    """GET /api/skins-pool/mine/ — pools my account hosts or is linked into."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from games.models import MultiSkinsGame, MultiSkinsLinkedRound
        from services.multi_skins import _summary_for_game
        acct = request.user.account

        games = {}
        for g in (MultiSkinsGame.objects
                  .filter(round__account=acct)
                  .select_related('round', 'round__course')):
            games[g.id] = g
        for lr in (MultiSkinsLinkedRound.objects
                   .filter(round__account=acct)
                   .select_related('game__round', 'game__round__course')):
            games[lr.game_id] = lr.game

        out = []
        for g in games.values():
            out.append({
                'host_round_id': g.round_id,
                'watch_token'  : g.round.watch_token,
                'course'       : g.round.course.name,
                'status'       : g.status,
                'summary'      : _summary_for_game(g),
            })
        return Response({'pools': out})


# ---------------------------------------------------------------------------
# Match Play
# ---------------------------------------------------------------------------

class MatchPlayResultView(APIView):
    """GET /api/foursomes/{id}/match-play/"""
    def get(self, request, pk):
        import logging
        _log = logging.getLogger(__name__)

        foursome = foursome_for_scorer(request.user, pk)

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
        foursome = foursome_for_scorer(request.user, pk)

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
        # Optional per-bracket handicap override.  When omitted the service
        # falls back to the round's handicap_mode / net_percent so a setup
        # POST that doesn't carry these fields keeps the previous behaviour.
        handicap_mode = request.data.get('handicap_mode', None)
        net_percent   = request.data.get('net_percent', None)
        try:
            setup_tournament_match_play(
                foursome,
                entry_fee=entry_fee,
                payout_config=payout_config,
                seed_order=seed_order,
                handicap_mode=handicap_mode,
                net_percent=net_percent,
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
        foursome = foursome_for_scorer(request.user, pk)
        from services.three_person_match import (
            three_person_match_summary,
            setup_three_person_match,
        )
        summary = three_person_match_summary(foursome)

        # Lazy auto-create: rounds with match_play active and a 3-real-player
        # foursome are auto-dispatched to TPM in setup_round, but rounds
        # created BEFORE that wiring (or where match_play was added later)
        # may not have a TPM record yet.  Create one on first GET so the
        # score-entry screen stops 404'ing.  Uses the service default
        # (SO Low) — admin can change via the setup screen.
        if summary is None:
            round_obj  = foursome.round
            active     = list(round_obj.active_games or [])
            real_count = sum(
                1 for m in foursome.memberships.all()
                if not m.player.is_phantom
            )
            if 'match_play' in active and real_count == 3:
                setup_three_person_match(
                    foursome, net_percent=round_obj.net_percent,
                )
                # Stamp three_person_match in fs active_games so the
                # _recalculate hook fires calculate_three_person_match.
                fs_games = list(foursome.active_games or [])
                if 'three_person_match' not in fs_games:
                    fs_games.append('three_person_match')
                    foursome.active_games = fs_games
                    foursome.save(update_fields=['active_games'])
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
        foursome = foursome_for_scorer(request.user, pk)
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
            'variant'      : config.variant,
            'custom_balls' : config.custom_balls,
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
                'variant'      : 'classic',
                'custom_balls' : None,
            }
        data['num_players']          = num_players
        data['is_tournament_round']  = is_tournament
        data['round_handicap_mode']  = round_obj.handicap_mode
        data['round_net_percent']    = round_obj.net_percent
        # Per-foursome real-player counts so the mobile setup screen can
        # show "splits to $X (foursome) / $Y (threesome)" helper text
        # under each payout field.  Drives Irish Rumble's group-total
        # payout UI.
        data['group_sizes']          = [
            sum(1 for m in fs.memberships.all() if not m.player.is_phantom)
            for fs in round_obj.foursomes.all()
        ]
        # Course pars per hole — drives the Shuffle variant preview and
        # the Custom variant's per-hole editor.  Ordered list of 18 ints
        # so the mobile client can address by 0-indexed hole.
        from services.irish_rumble import par_by_hole_for_round
        par_map = par_by_hole_for_round(round_obj)
        data['hole_pars'] = [par_map.get(h, 4) for h in range(1, 19)]
        return Response(data)

    def post(self, request, pk):
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
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

        # Derive the segments list from the chosen variant + course pars.
        # The scoring code reads segments verbatim, so each variant just
        # produces a different segments JSON at save time.
        from services.irish_rumble import (
            compute_segments, par_by_hole_for_round,
        )
        variant      = d.get('variant', 'classic')
        custom_balls = d.get('custom_balls') if variant == 'custom' else None
        par_by_hole  = par_by_hole_for_round(round_obj)
        segments     = compute_segments(variant, par_by_hole, custom_balls)

        from games.models import IrishRumbleConfig
        config, _ = IrishRumbleConfig.objects.update_or_create(
            round    = round_obj,
            defaults = {
                'handicap_mode': hcap_mode,
                'net_percent'  : net_pct,
                'entry_fee'    : d['entry_fee'],
                'payouts'      : d['payouts'],
                'segments'     : segments,
                'variant'      : variant,
                'custom_balls' : custom_balls,
            },
        )
        # Level true threesomes with a borrowed-4th phantom (whole-field donor
        # rotation) so every group counts the configured number of balls.
        # Idempotent — safe to re-run on every setup save.
        from services.irish_rumble import ensure_irish_rumble_phantom
        ensure_irish_rumble_phantom(round_obj)

        # Recalculate if there are already hole scores on file
        from services.irish_rumble import calculate_irish_rumble
        try:
            calculate_irish_rumble(round_obj)
        except Exception:
            pass  # No scores yet — calculation will run after first score save

        return Response(self._config_dict(config), status=status.HTTP_201_CREATED)


class IrishRumbleResultView(APIView):
    """GET /api/rounds/{id}/irish-rumble/ → segment + overall standings.

    Carries the per-group borrowed-4th donor status (`overall[].phantom`) so the
    score-entry screen can show a threesome its borrowed-ball / pending holes
    without parsing the whole leaderboard payload."""
    def get(self, request, pk):
        round_obj = round_for_reader(request.user, pk)
        from services.irish_rumble import irish_rumble_summary
        return Response(irish_rumble_summary(round_obj))


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
            'participant_player_ids': config.participant_player_ids or [],
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
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
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
                'participant_player_ids': d.get('participant_player_ids', []),
            },
        )
        return Response(self._config_dict(config), status=status.HTTP_201_CREATED)


# ---------------------------------------------------------------------------
# Stableford setup (round-level) + result
# ---------------------------------------------------------------------------

class StablefordSetupView(APIView):
    """
    GET  /api/rounds/{id}/stableford/setup/  → current config (or defaults).
    POST same — save the points table + handicap (net%/gross) + money, mark the
    round's `stableford` game active.
    """
    _PTS = ['pts_albatross', 'pts_eagle', 'pts_birdie',
            'pts_par', 'pts_bogey', 'pts_double']

    def _config_dict(self, config):
        return {
            'configured'         : True,
            'handicap_mode'      : config.handicap_mode,
            'net_percent'        : config.net_percent,
            'payout_style'       : config.payout_style,
            'per_point_rate'     : float(config.per_point_rate),
            'per_point_mode'     : config.per_point_mode,
            'loss_cap'           : (float(config.loss_cap)
                                    if config.loss_cap is not None else None),
            'entry_fee'          : float(config.entry_fee),
            'payouts'            : config.payouts or [],
            'excluded_player_ids': config.excluded_player_ids or [],
            'participant_player_ids': config.participant_player_ids or [],
            **{k: getattr(config, k) for k in self._PTS},
        }

    @staticmethod
    def _count_players(round_obj):
        return sum(
            1 for fs in round_obj.foursomes.all()
            for m in fs.memberships.all() if not m.player.is_phantom
        )

    def get(self, request, pk):
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
        from games.models import StablefordGame
        config = StablefordGame.objects.filter(round=round_obj).first()
        num = self._count_players(round_obj)
        if config is not None:
            return Response({'num_players': num, **self._config_dict(config)})
        return Response({
            'num_players'        : num,
            'configured'         : False,
            'handicap_mode'      : round_obj.handicap_mode
                                   if round_obj.handicap_mode in ('net', 'gross')
                                   else 'net',
            'net_percent'        : round_obj.net_percent,
            'payout_style'       : 'pool',
            'per_point_rate'     : 0.00,
            'per_point_mode'     : 'average',
            'loss_cap'           : None,
            'entry_fee'          : 0.00,
            'payouts'            : [],
            'excluded_player_ids': [],
            'pts_albatross': 5, 'pts_eagle': 4, 'pts_birdie': 3,
            'pts_par': 2, 'pts_bogey': 1, 'pts_double': 0,
        })

    def post(self, request, pk):
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
        from api.serializers import StablefordSetupSerializer
        ser = StablefordSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        d = ser.validated_data

        from games.models import StablefordGame
        config, _ = StablefordGame.objects.update_or_create(
            round=round_obj,
            defaults={
                'handicap_mode'      : d['handicap_mode'],
                'net_percent'        : d['net_percent'],
                'payout_style'       : d['payout_style'],
                'per_point_rate'     : d['per_point_rate'],
                'per_point_mode'     : d['per_point_mode'],
                'loss_cap'           : d.get('loss_cap'),
                'entry_fee'          : d['entry_fee'],
                'payouts'            : d['payouts'],
                'excluded_player_ids': d.get('excluded_player_ids', []),
                'participant_player_ids': d.get('participant_player_ids', []),
                **{k: d[k] for k in self._PTS},
            },
        )
        if 'stableford' not in (round_obj.active_games or []):
            round_obj.active_games = list(round_obj.active_games or []) + ['stableford']
            round_obj.save(update_fields=['active_games'])
        return Response(self._config_dict(config),
                        status=status.HTTP_201_CREATED)


class StablefordResultView(APIView):
    """GET /api/rounds/{id}/stableford/ → ranked standings + table + pool."""
    def get(self, request, pk):
        round_obj = round_for_reader(request.user, pk)
        from services.stableford import stableford_summary
        return Response(stableford_summary(round_obj))


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
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
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
        if not (request.user.is_staff or request.user.is_account_admin):
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
        existing_names = set(
            CourseModel.objects
            .for_account(request.user.account)
            .values_list('name', flat=True)
        )
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
        if not (request.user.is_staff or request.user.is_account_admin):
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
        existing_names = set(
            CourseModel.objects
            .for_account(request.user.account)
            .values_list('name', flat=True)
        )
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


class CoursePasteView(APIView):
    """
    POST /api/courses/paste/

    Hand-import a course (or re-rate an existing one's tees) from a
    pasted scorecard.  See services.course_paste for the input
    format.

    Body:
        {
          "name":              "Pebble Beach",   # required when not replacing
          "replace_course_id": null|int,         # update tees in-place on this course
          "paste":             "<multi-line blob>",
          "dry_run":           false             # true → just parse + return preview
        }

    Returns the same shape CourseDetailView does (CourseSerializer
    with nested tees), so the client can render the updated state.
    On dry_run=true returns the parsed structure WITHOUT a Course
    being persisted, so the mobile preview can show what would be
    saved before the user commits.
    """
    def post(self, request):
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only admins can paste-import courses.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        body          = request.data or {}
        paste_text    = (body.get('paste') or '').strip()
        if not paste_text:
            return Response(
                {'detail': 'Provide a "paste" string with tee specs '
                           'and 18 hole rows.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        from services.course_paste import (
            parse_paste, apply_parse, CoursePasteError,
        )

        try:
            parsed = parse_paste(paste_text)
        except CoursePasteError as exc:
            # parse_paste raises a DRF ValidationError so we can let
            # it bubble to a 400 directly — but we want the message
            # to land on a `paste` key the mobile can highlight.
            detail = exc.detail if isinstance(exc.detail, list) \
                else [exc.detail]
            return Response(
                {'paste': detail},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if body.get('dry_run'):
            return Response({
                'preview': True,
                'tees':    [
                    {
                        'name':          t['name'],
                        'slope':         t['slope'],
                        'course_rating': str(t['course_rating']),
                        'par':           t['par'],
                        'sex':           t['sex'],
                    }
                    for t in parsed['tees']
                ],
                'holes':   parsed['holes'],
            })

        replace_id = body.get('replace_course_id')
        if replace_id:
            course = account_get_or_404(
                Course, request.user.account, pk=replace_id,
            )
            updated = apply_parse(
                request.user.account, parsed, replace_course=course,
            )
        else:
            name = (body.get('name') or '').strip()
            if not name:
                return Response(
                    {'name': 'Course name is required when creating '
                             'a new course.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            updated = apply_parse(
                request.user.account, parsed, course_name=name,
            )

        # Re-fetch to load the freshly-attached tees.
        updated.refresh_from_db()
        return Response(
            CourseSerializer(updated).data,
            status=status.HTTP_201_CREATED if not replace_id
                   else status.HTTP_200_OK,
        )


class TeePasteView(APIView):
    """
    POST /api/courses/{pk}/tees/paste/

    Add (or re-rate) a single tee on an existing course using its
    own per-hole par + stroke index + yards.  Use this when:
      * combo tees aren't in the GolfCourseAPI catalogue,
      * men's and women's stroke indexes differ on the same hole,
      * one specific tee got re-rated by USGA and the others stayed
        the same.

    Body:
        {
          "name":          "White",      # required
          "slope":         130,
          "course_rating": "70.1",
          "sex":           "M" | "W" | null,
          "paste":         "<18 hole rows>",
          "dry_run":       false
        }

    Hole rows: 18 lines of "<hole> <par> <si> <yards>".  An
    optional first row of column headers ("Hole Par SI Yards") is
    accepted and ignored.

    Returns the parent course's full payload (CourseSerializer)
    so the client refreshes the per-course tees list in one shot.
    Matching tees update IN PLACE — the Tee pk is preserved, so
    rounds played on that tee aren't disturbed.
    """
    def post(self, request, pk):
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only admins can paste tees.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        course = account_get_or_404(
            Course, request.user.account, pk=pk,
        )

        body = request.data or {}
        name   = (body.get('name') or '').strip()
        if not name:
            return Response(
                {'name': 'Tee name is required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            slope  = int(body.get('slope'))
            from decimal import Decimal
            rating = Decimal(str(body.get('course_rating')))
        except (TypeError, ValueError):
            return Response(
                {'detail': 'slope must be an int and course_rating a '
                           'number.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        sex_raw = body.get('sex')
        if sex_raw in ('M', 'W', None, ''):
            sex = sex_raw or None
        elif sex_raw in ('U', 'unisex'):
            sex = None
        else:
            return Response(
                {'sex': 'sex must be "M", "W", or null.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        paste = (body.get('paste') or '').strip()
        if not paste:
            return Response(
                {'paste': 'Provide 18 hole rows in the paste.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        from services.course_paste import (
            parse_single_tee_holes, apply_single_tee, CoursePasteError,
        )

        try:
            holes = parse_single_tee_holes(paste)
        except CoursePasteError as exc:
            detail = exc.detail if isinstance(exc.detail, list) \
                else [exc.detail]
            return Response(
                {'paste': detail},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if not (55 <= slope <= 155):
            return Response(
                {'slope': f'Slope {slope} must be 55-155.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        from decimal import Decimal as _D
        if not (_D('60') <= rating <= _D('80')):
            return Response(
                {'course_rating': f'Rating {rating} must be 60-80.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if body.get('dry_run'):
            return Response({
                'preview': True,
                'tee': {
                    'name':          name,
                    'slope':         slope,
                    'course_rating': str(rating),
                    'sex':           sex,
                    'par':           sum(h['par'] for h in holes),
                },
                'holes': holes,
            })

        apply_single_tee(
            course,
            tee_name=name, slope=slope, course_rating=rating,
            sex=sex, holes=holes,
        )
        course.refresh_from_db()
        return Response(
            CourseSerializer(course).data,
            status=status.HTTP_200_OK,
        )


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
        if not (request.user.is_staff or request.user.is_account_admin):
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

        # Quality gate — reject courses with broken hole data (e.g. all-18
        # stroke indexes) BEFORE they poison the shared catalog and every
        # account that later copies from it.  Runs before any DB write.
        from services.course_quality import (
            assert_course_quality, CourseQualityError,
        )
        try:
            assert_course_quality(api_course)
        except CourseQualityError as exc:
            return Response(
                {
                    'detail': 'This course has invalid hole data and was not '
                              'imported.',
                    'problems': exc.problems,
                },
                status=status.HTTP_422_UNPROCESSABLE_ENTITY,
            )

        from core.models import Course as CourseModel, Tee as TeeModel
        from services.catalog import (
            upsert_catalog_course, clone_catalog_to_account,
        )
        from .serializers import CourseSerializer

        # Detect an existing copy in THIS account — prefer the stable
        # golf_api_id, fall back to name for courses imported before it existed.
        existing = (
            CourseModel.objects
            .for_account(request.user.account)
            .filter(golf_api_id=str(course_id))
            .first()
            or CourseModel.objects
            .for_account(request.user.account)
            .filter(name=course_name)
            .first()
        )

        if existing and not force_update:
            return Response(
                {
                    'already_exists': True,
                    'course'        : CourseSerializer(existing).data,
                },
                status=status.HTTP_409_CONFLICT,
            )

        import logging as _logging
        _log = _logging.getLogger(__name__)
        tees = api_course.get('tees', [])
        _log.info(
            'CourseImportView: course_id=%s name=%r tee_count=%d',
            course_id, course_name, len(tees),
        )
        incomplete_tees = [
            t.get('name', '?') for t in tees if len(t.get('holes', [])) != 18
        ]
        for name in incomplete_tees:
            _log.warning('Tee "%s" imported without full 18-hole data.', name)

        # ── Upsert the shared catalog, then copy-on-add into this account ─────
        catalog_course = upsert_catalog_course(api_course, course_id, course_name)
        # Backfill provenance on a legacy name-matched copy so future re-imports
        # dedupe by golf_api_id.
        if existing is not None and not existing.golf_api_id:
            existing.golf_api_id = str(course_id)
            existing.save(update_fields=['golf_api_id'])
        course_obj, created = clone_catalog_to_account(
            catalog_course, request.user.account,
            replace_tees=existing is not None,  # force_update path refreshes tees
        )

        tee_count = TeeModel.objects.filter(course=course_obj).count()
        result = {
            'already_exists' : existing is not None,
            'created'        : created,
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


class CatalogCourseListView(APIView):
    """
    GET /api/catalog/courses/?q=<text>

    Search the SHARED course catalog (deduped across all accounts by
    golf_api_id) by name or city.  This is the fast, free, network-shared source
    a user adds courses from — a friend's imported course shows up here with no
    re-import.  Each result carries `already_in_account` so the UI can show what
    the caller has already added.
    """
    def get(self, request):
        from django.db.models import Q
        from core.models import CatalogCourse, Course as CourseModel
        from .serializers import CatalogCourseSerializer

        q = (request.query_params.get('q') or '').strip()
        qs = CatalogCourse.objects.all()
        if q:
            qs = qs.filter(Q(name__icontains=q) | Q(city__icontains=q))
        qs = qs.prefetch_related('tees')[:50]

        owned_api_ids = set(
            CourseModel.objects
            .for_account(request.user.account)
            .exclude(golf_api_id__isnull=True)
            .values_list('golf_api_id', flat=True)
        )
        data = CatalogCourseSerializer(
            qs, many=True, context={'owned_api_ids': owned_api_ids},
        ).data
        return Response({'courses': data})


class CatalogCourseAddView(APIView):
    """
    POST /api/catalog/courses/<pk>/add/

    Copy-on-add: clone a shared catalog course into the caller's account
    (no GolfCourseAPI call).  Idempotent — returns the existing copy if the
    account already has it.  The clone is account-owned, so tee priority and
    any edits stay local.
    """
    def post(self, request, pk):
        from core.models import CatalogCourse
        from services.catalog import clone_catalog_to_account
        from .serializers import CourseSerializer

        catalog_course = get_object_or_404(CatalogCourse, pk=pk)
        course, created = clone_catalog_to_account(
            catalog_course, request.user.account,
        )
        return Response(
            {'created': created, 'course': CourseSerializer(course).data},
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class CourseFindView(APIView):
    """
    GET /api/courses/find/?q=<text>

    Unified, one-box course search.  Merges three sources into a single deduped
    list so the user just types a course name and picks — no visible "search the
    catalog, then search the full database" steps:
      1. the caller's own account courses (instant select, no add),
      2. the shared catalog (clone-on-add, no GolfCourseAPI call),
      3. a live GolfCourseAPI search (imported with its tees on selection).
    Dedup is by golf_api_id, then by (name, city), preferring the cheapest add
    path (account > catalog > api) so a course in more than one source appears
    once.  The GolfCourseAPI call is BEST-EFFORT: if it errors or times out, the
    local results still return — the picker never breaks on a slow upstream.

    Each result carries `source` + the id the client needs to add it:
      * source=account → course_id  (already owned; just select it)
      * source=catalog → catalog_id (POST /catalog/courses/<id>/add/)
      * source=api     → golf_api_id (POST /courses/import/)
    """
    def get(self, request):
        from django.db.models import Q
        from core.models import CatalogCourse, Course as CourseModel

        q = (request.query_params.get('q') or '').strip()
        if len(q) < 2:
            return Response({'courses': []})

        account = request.user.account
        out = []
        seen_api = set()    # golf_api_id strings already represented
        seen_name = set()   # "name|city" lowercased — dedup across sources w/o a shared id

        def name_key(name, city):
            return f'{(name or "").strip().lower()}|{(city or "").strip().lower()}'

        # 1. The caller's own courses — instant select.
        own = (CourseModel.objects
               .for_account(account)
               .filter(Q(name__icontains=q) | Q(city__icontains=q))
               .prefetch_related('tees')
               .order_by('name')[:25])
        for c in own:
            out.append({
                'source': 'account', 'name': c.name,
                'city': c.city, 'state': c.state, 'country': c.country,
                'course_id': c.id, 'catalog_id': None,
                'golf_api_id': c.golf_api_id or '',
                'in_account': True,
                # Current revisions only (uses the prefetched list, no extra query).
                'tee_count': sum(1 for t in c.tees.all() if t.is_current),
            })
            if c.golf_api_id:
                seen_api.add(str(c.golf_api_id))
            seen_name.add(name_key(c.name, c.city))

        # 2. Shared catalog — clone-on-add (free).
        cat = (CatalogCourse.objects
               .filter(Q(name__icontains=q) | Q(city__icontains=q))
               .prefetch_related('tees')
               .order_by('name')[:50])
        for cc in cat:
            if str(cc.golf_api_id) in seen_api:
                continue
            if name_key(cc.name, cc.city) in seen_name:
                continue
            out.append({
                'source': 'catalog', 'name': cc.name,
                'city': cc.city, 'state': cc.state, 'country': cc.country,
                'course_id': None, 'catalog_id': cc.id,
                'golf_api_id': cc.golf_api_id,
                'in_account': False, 'tee_count': cc.tees.count(),
            })
            seen_api.add(str(cc.golf_api_id))
            seen_name.add(name_key(cc.name, cc.city))

        # 3. Live GolfCourseAPI — best-effort; imported on selection.
        try:
            from services.golf_api_client import search_courses
            api_courses = search_courses(q)
        except Exception:
            import logging
            import traceback
            logging.getLogger(__name__).warning(
                'CourseFind: GolfCourseAPI search failed; returning local '
                'results only:\n%s', traceback.format_exc())
            api_courses = []
        for ac in api_courses:
            aid = str(ac.get('id') or '').strip()
            if not aid or aid in seen_api:
                continue
            name = _course_display_name(ac)
            if name_key(name, ac.get('city')) in seen_name:
                continue
            out.append({
                'source': 'api', 'name': name,
                'city': ac.get('city', ''), 'state': ac.get('state', ''),
                'country': ac.get('country', ''),
                'course_id': None, 'catalog_id': None, 'golf_api_id': aid,
                'in_account': False, 'tee_count': None,
            })
            seen_api.add(aid)
            seen_name.add(name_key(name, ac.get('city')))

        return Response({'courses': out[:60]})


class PinkBallFoursomeOrderView(APIView):
    """
    POST /api/foursomes/{id}/pink-ball/order/
        Body: {"order": [player_pk, ...]}  (exactly 18 entries)
        Saves the custom rotation for this foursome.
    """

    def post(self, request, pk):
        foursome = foursome_for_scorer(request.user, pk)
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
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
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
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
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
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
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
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
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
        player    = account_get_or_404(
            Player, request.user.account, pk=player_id,
        )

        # Remove player from any other team in this tournament first
        for other_team in tt.teams.exclude(pk=team.pk):
            other_team.players.remove(player)

        team.players.add(player)
        return Response(_team_roster(team))

    def delete(self, request, pk, team_pk, player_pk):
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
        tt         = get_object_or_404(TeamTournament, tournament=tournament)
        team       = get_object_or_404(TournamentTeam, pk=team_pk, tournament=tt)

        if tt.draft_complete:
            return Response(
                {'detail': 'Draft is complete. Rosters are locked.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        player = account_get_or_404(
            Player, request.user.account, pk=player_pk,
        )
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
        tournament = account_get_or_404(Tournament, request.user.account, pk=pk)
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
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)

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

        round_format = d.get('round_format', 'custom')
        rc = RyderCupRoundConfig.objects.create(
            round              = round_obj,
            tournament         = tt,
            nassau_point_value = d['nassau_point_value'],
            point_multiplier   = d['point_multiplier'],
            notes              = d['notes'],
            round_format       = round_format,
        )

        # Per-foursome configs
        # Collect phantom foursomes to configure after all Nassau games are set up
        # (donors from other foursomes need their memberships to exist first).
        _phantom_foursomes_to_configure: list = []

        for fs_data in d.get('foursomes', []):
            foursome = get_object_or_404(Foursome, pk=fs_data['foursome_id'])
            team1 = get_object_or_404(TournamentTeam, pk=fs_data['team1_id'], tournament=tt) if fs_data.get('team1_id') else None
            team2 = get_object_or_404(TournamentTeam, pk=fs_data['team2_id'], tournament=tt) if fs_data.get('team2_id') else None
            # 'triple_cup' round format locks every foursome to TC —
            # the wizard payload may omit per-foursome game_type
            # (and historic payloads that include it are overridden
            # to keep the round internally consistent).
            if round_format == 'triple_cup':
                fs_data['game_type'] = GameType.TRIPLE_CUP
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

                # Delete any existing team Nassau for this foursome to avoid
                # duplicates (scoped to game_type so a coexisting Singles Match
                # survives; setup_nassau re-creates the 'nassau' row).
                from games.models import NassauGame
                NassauGame.objects.filter(foursome=foursome,
                                          game_type='nassau').delete()
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

            # Triple Cup: 1 fourball + 1 alt-shot + 2 singles per
            # foursome, 4 cup-points each.  Even foursomes only for
            # now — 2v1 cup handling (with cross-foursome donor for
            # the fourball phantom) comes in the follow-up phase.
            elif fs_data['game_type'] == GameType.TRIPLE_CUP:
                from services.triple_cup import setup_triple_cup
                real_pids_tc = set(
                    foursome.memberships.filter(player__is_phantom=False)
                    .values_list('player_id', flat=True)
                )
                t1_ids = [p.pk for p in (team1.players.all() if team1 else [])
                          if p.pk in real_pids_tc]
                t2_ids = [p.pk for p in (team2.players.all() if team2 else [])
                          if p.pk in real_pids_tc]
                try:
                    setup_triple_cup(
                        foursome,
                        team1_ids     = t1_ids,
                        team2_ids     = t2_ids,
                        handicap_mode = round_obj.handicap_mode,
                        net_percent   = round_obj.net_percent,
                    )
                except (ValueError, Exception) as _e:
                    import logging
                    logging.getLogger(__name__).warning(
                        'triple_cup setup failed for foursome %s: %s',
                        foursome.id, _e,
                    )
                existing_games = list(foursome.active_games or [])
                if 'triple_cup' not in existing_games:
                    existing_games.append('triple_cup')
                    foursome.active_games = existing_games
                    foursome.save(update_fields=['active_games'])

        # Configure cross-foursome phantom rotation for Four Ball foursomes.
        # Done after the main loop so all foursomes have memberships and the
        # donor players (from other foursomes on the same team) are in the DB.
        # Donor pool = the 3 earliest-teeing foursomes only, so first
        # validate that those 3 are full 4-player groups; otherwise the
        # short-roster groups later in the round have nothing to pull
        # from.  Surfaces clear errors instead of mysterious empty
        # phantom scores at game time.
        phantom_setup_results = []
        if _phantom_foursomes_to_configure:
            from scoring.phantom import (
                setup_cross_foursome_phantom,
                validate_donor_foursomes,
            )
            donor_errors = validate_donor_foursomes(round_obj)
            if donor_errors:
                # Module-level Response/status imports — early-return
                # rolls back the @transaction.atomic on this post().
                return Response(
                    {'detail': 'Donor foursome validation failed.',
                     'errors': donor_errors},
                    status=status.HTTP_400_BAD_REQUEST,
                )
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

        # Same treatment for Triple Cup so leaderboard + recalc fire.
        has_tc = any(
            fs_d['game_type'] == GameType.TRIPLE_CUP
            for fs_d in d.get('foursomes', [])
        )
        if has_tc:
            round_games = list(round_obj.active_games or [])
            if 'triple_cup' not in round_games:
                round_games.append('triple_cup')
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
        # Cross-account read: shared-round participants/watchers load the cup
        # config too (mirror CupRoundLiveView / LeaderboardView).
        round_obj = round_for_reader(request.user, pk)
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
        # Cross-account read: a participant/watcher in another account (shared
        # round) must be able to load cup standings — mirror LeaderboardView.
        round_obj = round_for_reader(request.user, pk)
        from services.cup_standings import cup_round_live_summary
        summary = cup_round_live_summary(round_obj)
        if summary is None:
            return Response(
                {'detail': 'No cup config for this round.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


class RyderCupChangeGameView(APIView):
    """
    POST /api/rounds/<pk>/ryder-cup/change-game/

    Swap the cup game for every foursome in this round without
    rebuilding from scratch.  Real-world need: cup tournaments
    routinely shift formats day-to-day — Day 2 might flip from
    Singles Nassau to Four Ball without changing the player roster
    or team draft.

    Body:
      {
        "game_type":   "nassau"|"quota_nassau"|"singles_nassau"|"singles_18",
        "point_value": "1.00"   # optional; defaults to keeping each
                                # foursome's existing point_value
      }

    What it preserves
      * FoursomeMembership rows (players + tees stay put)
      * TournamentTeam membership (drives team1/team2 derivation)
      * The RyderCupRoundConfig row itself (multiplier, notes, etc.)

    What it replaces
      * Each foursome's per-game model (NassauGame / QuotaNassauGame /
        cup_singles MatchPlayBracket) — old scoring data for the
        previous game is wiped.  This matches the existing setup
        wizard's behaviour for the same swap.

    What it rejects (400 / 501)
      * Irish Rumble and match_play targets need extra structural
        info (cross-foursome pairings, brackets) — use the full
        wizard.

    Admin-only.
    """
    permission_classes = [IsAuthenticated]

    @transaction.atomic
    def post(self, request, pk):
        if not (request.user.is_staff or request.user.is_account_admin):
            return Response(
                {'detail': 'Only admins can change the cup game.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        round_obj = account_get_or_404(Round, request.user.account, pk=pk)

        body = request.data or {}
        game_type = (body.get('game_type') or '').strip()
        if not game_type:
            return Response(
                {'game_type': 'game_type is required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        pv_raw = body.get('point_value')
        point_value = None
        if pv_raw not in (None, ''):
            try:
                from decimal import Decimal
                point_value = Decimal(str(pv_raw))
            except Exception:
                return Response(
                    {'point_value': 'point_value must be a number.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )

        from services.cup_change_game import change_round_game
        try:
            summary = change_round_game(
                round_obj,
                game_type=game_type,
                point_value=point_value,
            )
        except NotImplementedError as exc:
            return Response(
                {'detail': str(exc)},
                status=status.HTTP_501_NOT_IMPLEMENTED,
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
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
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
        foursome = foursome_for_scorer(request.user, pk)
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
        foursome = foursome_for_scorer(request.user, pk)
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
        round_obj = account_get_or_404(Round, request.user.account, pk=pk)
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


# ---------------------------------------------------------------------------
# Messaging — round message feed (chat + server event cards)
# ---------------------------------------------------------------------------

class RoundMessagesView(APIView):
    """
    GET  /api/rounds/<pk>/messages/?since=<id>  → {messages, unread, my_player_id}
    POST /api/rounds/<pk>/messages/  {body}     → post a chat message (201)

    Audience = the leaderboard reader set (round participants across foursomes +
    invited watchers), via round_for_reader.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        from accounts.scoring_access import round_for_reader
        from services import messaging
        rnd = round_for_reader(request.user, pk)
        thread = messaging.get_or_create_thread(rnd)
        try:
            since = int(request.query_params.get('since', 0))
        except (TypeError, ValueError):
            since = 0
        msgs = messaging.list_messages(thread, since_id=since)
        player = getattr(request.user, 'player_profile', None)
        return Response({
            'messages':     MessageSerializer(msgs, many=True).data,
            'unread':       messaging.unread_count(thread, request.user),
            'my_player_id': player.id if player else None,
        })

    def post(self, request, pk):
        from accounts.scoring_access import round_for_reader
        from services import messaging
        rnd = round_for_reader(request.user, pk)
        body = (request.data.get('body') or '').strip()
        if not body:
            return Response({'detail': 'Message body required.'},
                            status=status.HTTP_400_BAD_REQUEST)
        thread = messaging.get_or_create_thread(rnd)
        author = getattr(request.user, 'player_profile', None)
        msg = messaging.post_user_message(thread, author, body)
        # Your own message shouldn't count as unread for you.
        messaging.mark_read(thread, request.user, msg.id)
        return Response(MessageSerializer(msg).data,
                        status=status.HTTP_201_CREATED)


class RoundMessagesReadView(APIView):
    """POST /api/rounds/<pk>/messages/read/  {last_seen_id}  → {unread}"""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        from accounts.scoring_access import round_for_reader
        from services import messaging
        rnd = round_for_reader(request.user, pk)
        thread = messaging.get_or_create_thread(rnd)
        messaging.mark_read(thread, request.user,
                            request.data.get('last_seen_id', 0))
        return Response({'unread': messaging.unread_count(thread, request.user)})
