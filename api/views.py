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

from core.models import Player, Tee, Course, HandicapMode
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
        from services.tournament_match_play import calculate_tournament_match_play
        calculate_tournament_match_play(foursome)

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
        provider = PhantomScoreProvider(foursome)
        if provider.has_phantom:
            phantom_gross = provider.phantom_gross_scores()
            for h in holes_out:
                hole_num = h['hole_number']
                if hole_num in phantom_gross:
                    h['phantom'] = {
                        'gross_score'            : phantom_gross[hole_num],
                        'is_phantom'             : True,
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
        from services.tournament_match_play import tournament_match_play_summary
        from games.models import ThreePersonMatch as _TPM
        tpm_fs_ids = set(
            _TPM.objects
            .filter(foursome__round=round_obj)
            .values_list('foursome_id', flat=True)
        )
        mp_groups = []
        for fs in foursomes:
            if fs.id in tpm_fs_ids:
                continue  # 3-person group plays 5-3-1, not bracket match play
            s = tournament_match_play_summary(fs)
            if s is not None:
                mp_groups.append({
                    'foursome_id' : fs.id,
                    'group_number': fs.group_number,
                    'summary'     : s,
                })
        if mp_groups:
            games['match_play'] = {'label': 'Match Play', 'by_group': mp_groups}

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

        if 'low_net' in active_games:
            from services.low_net_championship import low_net_championship_summary
            games['low_net'] = {
                'label'  : 'Low Net Championship',
                **low_net_championship_summary(tournament),
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

        lb_games = _build_leaderboard(round_obj)
        return Response({
            'round_id'    : round_obj.id,
            'status'      : round_obj.status,
            'round_date'  : str(round_obj.date),
            'course'      : str(round_obj.course),
            'active_games': _leaderboard_active_games(round_obj, lb_games),
            'games'       : lb_games,
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
        t        = round_obj.tournament
        lb_games = _build_leaderboard(round_obj)
        return Response({
            'round_id'              : round_obj.id,
            'round_date'            : str(round_obj.date),
            'course'                : str(round_obj.course),
            'status'                : round_obj.status,
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
        from services.tournament_match_play import tournament_match_play_summary
        # Do NOT recalculate here — _recalculate_games handles that on every
        # score submission.  Recalculating on every GET caused concurrent
        # delete→bulk_create races (UniqueViolation) when the 3-second polling
        # timer and a score-submit response both called loadMatchPlay at once.
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
        # score submission.  (Tournament-level games live on tournament.active_games,
        # not on the round or foursome, so without this the bracket would never
        # be recalculated as hole scores come in.)
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
