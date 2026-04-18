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
from django.db import transaction
from django.shortcuts import get_object_or_404

from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.permissions import AllowAny, IsAuthenticated

from core.models import Player, Tee
from tournament.models import Tournament, Round, Foursome, FoursomeMembership
from scoring.models import HoleScore

from .serializers import (
    PlayerSerializer, TeeSerializer,
    TournamentSerializer, RoundSerializer, FoursomeSerializer,
    ScoreSubmitSerializer, RoundSetupSerializer,
    TournamentCreateSerializer, RoundCreateSerializer,
    NassauSetupSerializer, SixesSetupSerializer,
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
    """
    round_obj    = foursome.round
    active_games = round_obj.active_games or []

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

    if 'match_play' in active_games:
        from services.match_play import calculate_match_play
        calculate_match_play(foursome)

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


def _build_scorecard(foursome: Foursome) -> dict:
    """Build the scorecard dict for a foursome."""
    tee          = foursome.round.course
    memberships  = list(foursome.memberships.select_related('player').all())
    real_members = [m for m in memberships if not m.player.is_phantom]

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
            scores_for_hole.append({
                'player_id'        : m.player_id,
                'player_name'      : m.player.name,
                'hole_number'      : hole_num,
                'gross_score'      : hs.gross_score       if hs else None,
                'handicap_strokes' : hs.handicap_strokes  if hs else m.handicap_strokes_on_hole(stroke_index),
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
                 'summary': {'totals': skins_summary(fs)}}
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
            'label'  : 'Pink Ball',
            'results': red_ball_summary(round_obj),
        }

    if 'low_net_round' in active_games:
        from services.low_net_round import low_net_round_summary
        games['low_net_round'] = {
            'label'  : 'Low Net',
            'results': low_net_round_summary(round_obj),
        }

    if 'irish_rumble' in active_games:
        from services.irish_rumble import irish_rumble_summary
        games['irish_rumble'] = {
            'label'  : 'Irish Rumble',
            'results': irish_rumble_summary(round_obj),
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
        games['nassau'] = {
            'label'   : 'Nassau',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': nassau_summary(fs)}
                for fs in foursomes
            ],
        }

    if 'match_play' in active_games:
        from services.match_play import match_play_summary
        games['match_play'] = {
            'label'   : 'Match Play',
            'by_group': [
                {'foursome_id': fs.id, 'group_number': fs.group_number,
                 'summary': match_play_summary(fs)}
                for fs in foursomes
            ],
        }

    return games


def _auto_setup_games(round_obj: Round, foursomes: list) -> None:
    """
    Auto-configure per-foursome game data immediately after the draw.
    Teams are assigned by handicap rank: players ranked 1st & 3rd form
    Team 1, 2nd & 4th form Team 2 (balanced pairing).
    Called when RoundSetupView receives auto_setup_games=True.
    """
    active = round_obj.active_games or []

    for fs in foursomes:
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
            from services.match_play import setup_match_play
            setup_match_play(fs)


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

class LoginView(APIView):
    """
    POST /api/auth/login/
    Body: { "username": "...", "password": "..." }
    Returns: { "token": "...", "player_id": N, "name": "...", "handicap_index": "..." }
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

        player_data = {}
        try:
            p = user.player_profile
            player_data = {
                'player_id'     : p.id,
                'name'          : p.name,
                'handicap_index': str(p.handicap_index),
            }
        except Exception:
            pass  # admin/staff user with no player profile

        return Response({'token': token.key, **player_data})


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
    """GET /api/auth/me/ — current player profile."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        try:
            player = request.user.player_profile
            return Response(PlayerSerializer(player).data)
        except Exception:
            return Response(
                {'detail': 'No player profile linked to this account.'},
                status=status.HTTP_404_NOT_FOUND,
            )


# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

class PlayerListView(APIView):
    def get(self, request):
        players = Player.objects.filter(is_phantom=False).order_by('name')
        return Response(PlayerSerializer(players, many=True).data)

    def post(self, request):
        ser = PlayerSerializer(data=request.data)
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
        """POST /api/tournaments/ — create a new tournament."""
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

        round_obj = Round.objects.create(
            tournament   = tournament,
            round_number = d['round_number'],
            date         = d['date'],
            course       = course,
            status       = 'pending',
            active_games = d['active_games'],
            bet_unit     = d['bet_unit'],
            notes        = d['notes'],
        )
        return Response(RoundSerializer(round_obj).data,
                        status=status.HTTP_201_CREATED)


class RoundDetailView(APIView):
    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects
                 .select_related('course')
                 .prefetch_related('foursomes__memberships__player'),
            pk=pk,
        )
        return Response(RoundSerializer(round_obj).data)


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

        # Pre-populate phantom player scores for game calculators
        for fs in foursomes:
            if fs.has_phantom:
                create_phantom_hole_scores(fs)

        # Mark round in_progress now that it has players
        round_obj.status = 'in_progress'
        round_obj.save(update_fields=['status'])

        if d['auto_setup_games']:
            _auto_setup_games(round_obj, foursomes)

        round_obj = (
            Round.objects
            .select_related('course')
            .prefetch_related('foursomes__memberships__player')
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
        tee            = foursome.round.course
        hole_info      = tee.hole(hole_number)
        stroke_index   = hole_info.get('stroke_index', 18)

        membership_map = {m.player_id: m for m in foursome.memberships.all()}

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

        round_obj = foursome.round
        return Response({
            'scorecard'  : _build_scorecard(foursome),
            'leaderboard': {
                'round_id'   : round_obj.id,
                'round_date' : str(round_obj.date),
                'course'     : str(round_obj.course),
                'status'     : round_obj.status,
                'active_games': round_obj.active_games or [],
                'games'      : _build_leaderboard(round_obj),
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

        return Response({
            'round_id'    : round_obj.id,
            'status'      : round_obj.status,
            'round_date'  : str(round_obj.date),
            'course'      : str(round_obj.course),
            'active_games': round_obj.active_games or [],
            'games'       : _build_leaderboard(round_obj),
        })


# ---------------------------------------------------------------------------
# Leaderboard
# ---------------------------------------------------------------------------

class LeaderboardView(APIView):
    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects.select_related('course').prefetch_related('foursomes'),
            pk=pk,
        )
        return Response({
            'round_id'   : round_obj.id,
            'round_date' : str(round_obj.date),
            'course'     : str(round_obj.course),
            'status'     : round_obj.status,
            'active_games': round_obj.active_games or [],
            'games'      : _build_leaderboard(round_obj),
        })


# ---------------------------------------------------------------------------
# Nassau 9-9-18
# ---------------------------------------------------------------------------

class NassauSetupView(APIView):
    """
    POST /api/foursomes/{id}/nassau/setup/
    Body: { "team1_player_ids": [...], "team2_player_ids": [...], "press_pct": 0.5 }
    """
    def post(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        ser = NassauSetupSerializer(data=request.data)
        ser.is_valid(raise_exception=True)

        from services.nassau import setup_nassau
        game = setup_nassau(
            foursome,
            team1_ids = ser.validated_data['team1_player_ids'],
            team2_ids = ser.validated_data['team2_player_ids'],
            press_pct = ser.validated_data['press_pct'],
        )
        return Response({'nassau_game_id': game.id}, status=status.HTTP_201_CREATED)


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
        segments = setup_sixes(foursome, ser.validated_data['segments'])
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

        seg = SixesSegment.objects.filter(foursome=foursome, is_extra=True).first()
        if seg is None:
            return Response(
                {'error': 'No extra segment found for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )

        t1_ids = request.data.get('team1_player_ids', [])
        t2_ids = request.data.get('team2_player_ids', [])
        if len(t1_ids) != 2 or len(t2_ids) != 2:
            return Response(
                {'error': 'Each team must have exactly 2 player IDs.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Replace any existing teams on the extra segment
        seg.teams.all().delete()

        t1 = SixesTeam.objects.create(
            segment=seg, team_number=1, team_select_method='loser_choice')
        t1.players.set(t1_ids)

        t2 = SixesTeam.objects.create(
            segment=seg, team_number=2, team_select_method='loser_choice')
        t2.players.set(t2_ids)

        return Response(sixes_summary(foursome), status=status.HTTP_200_OK)


class SixesResultView(APIView):
    """GET /api/foursomes/{id}/sixes/"""
    def get(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from services.sixes import sixes_summary
        return Response(sixes_summary(foursome))


# ---------------------------------------------------------------------------
# Match Play
# ---------------------------------------------------------------------------

class MatchPlayResultView(APIView):
    """GET /api/foursomes/{id}/match-play/"""
    def get(self, request, pk):
        foursome = get_object_or_404(Foursome, pk=pk)
        from services.match_play import match_play_summary
        summary = match_play_summary(foursome)
        if summary is None:
            return Response(
                {'detail': 'No match play bracket set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)
