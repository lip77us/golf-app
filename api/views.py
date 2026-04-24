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

from core.models import Player, Tee, Course
from tournament.models import Tournament, Round, Foursome, FoursomeMembership
from scoring.models import HoleScore

from .serializers import (
    PlayerSerializer, PlayerCreateSerializer, TeeSerializer,
    TournamentSerializer, RoundSerializer, FoursomeSerializer,
    ScoreSubmitSerializer, RoundSetupSerializer,
    TournamentCreateSerializer, RoundCreateSerializer,
    NassauSetupSerializer, NassauPressSerializer,
    SixesSetupSerializer, CourseSerializer,
    Points531SetupSerializer, CasualRoundSummarySerializer,
    IrishRumbleSetupSerializer, LowNetSetupSerializer,
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

    if 'points_531' in active_games:
        from services.points_531 import calculate_points_531
        calculate_points_531(foursome)

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
        games['irish_rumble'] = {
            'label': 'Irish Rumble',
            **irish_rumble_summary(round_obj),
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
            tournament    = tournament,
            round_number  = d['round_number'],
            date          = d['date'],
            course        = course,
            status        = 'pending',
            active_games  = d['active_games'],
            bet_unit      = d['bet_unit'],
            handicap_mode = d.get('handicap_mode', 'net'),
            net_percent   = d.get('net_percent', 100),
            notes         = d['notes'],
            created_by    = created_by,
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
                 .prefetch_related('foursomes__memberships__player'),
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
        foursome = get_object_or_404(Foursome, pk=pk)
        from services.match_play import match_play_summary
        summary = match_play_summary(foursome)
        if summary is None:
            return Response(
                {'detail': 'No match play bracket set up for this foursome.'},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(summary)


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
            'bet_unit'     : float(config.bet_unit),
            'segments'     : config.segments,
        }

    def get(self, request, pk):
        round_obj = get_object_or_404(Round, pk=pk)
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
                'bet_unit'     : 1.00,
                'segments'     : _IR_DEFAULT_SEGMENTS,
            }
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
                'bet_unit'     : d['bet_unit'],
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
            'configured'   : True,
            'handicap_mode': config.handicap_mode,
            'net_percent'  : config.net_percent,
            'entry_fee'    : float(config.entry_fee),
            'payouts'      : config.payouts or [],
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

    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects.prefetch_related('foursomes__memberships__player'),
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
                'num_players'  : num_players,
                'configured'   : False,
                'handicap_mode': round_obj.handicap_mode,
                'net_percent'  : round_obj.net_percent,
                'entry_fee'    : 0.00,
                'payouts'      : [],
            }
        data['is_tournament_round'] = is_tournament
        data['round_handicap_mode'] = round_obj.handicap_mode
        data['round_net_percent']   = round_obj.net_percent
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
                'handicap_mode': hcap_mode,
                'net_percent'  : net_pct,
                'entry_fee'    : d['entry_fee'],
                'payouts'      : d['payouts'],
            },
        )
        return Response(self._config_dict(config), status=status.HTTP_201_CREATED)


# ---------------------------------------------------------------------------
# Pink Ball setup (round-level) + per-foursome order
# ---------------------------------------------------------------------------

class PinkBallSetupView(APIView):
    """
    GET  /api/rounds/{id}/pink-ball/setup/
        Returns current config (ball_color, bet_unit) plus each foursome's
        current pink_ball_order and player list.

    POST /api/rounds/{id}/pink-ball/setup/
        Save ball_color and bet_unit.
    """

    @staticmethod
    def _foursome_data(fs):
        real_members = (
            fs.memberships.filter(player__is_phantom=False)
                          .select_related('player')
                          .order_by('id')
        )
        return {
            'foursome_id' : fs.pk,
            'group_number': fs.group_number,
            'players'     : [
                {'id': m.player.pk, 'name': m.player.name,
                 'short_name': m.player.short_name}
                for m in real_members
            ],
            'order': fs.pink_ball_order or [],
        }

    def get(self, request, pk):
        round_obj = get_object_or_404(
            Round.objects.prefetch_related('foursomes__memberships__player'),
            pk=pk,
        )
        from games.models import PinkBallConfig
        try:
            config      = round_obj.pink_ball_config
            configured  = True
            ball_color  = config.ball_color
            bet_unit    = float(config.bet_unit)
            places_paid = config.places_paid
        except PinkBallConfig.DoesNotExist:
            configured  = False
            ball_color  = 'Pink'
            bet_unit    = 1.00
            places_paid = 1

        foursomes_data = [
            self._foursome_data(fs)
            for fs in round_obj.foursomes.order_by('group_number')
        ]
        return Response({
            'configured' : configured,
            'ball_color' : ball_color,
            'bet_unit'   : bet_unit,
            'places_paid': places_paid,
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
                'ball_color' : d['ball_color'],
                'bet_unit'   : d['bet_unit'],
                'places_paid': d.get('places_paid', 1),
            },
        )
        return Response({
            'configured' : True,
            'ball_color' : config.ball_color,
            'bet_unit'   : float(config.bet_unit),
            'places_paid': config.places_paid,
        }, status=status.HTTP_201_CREATED)


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
