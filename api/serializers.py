"""
api/serializers.py
------------------
DRF serializers for the Golf App API.

Organised into sections:
  1. Core / reference data  (Player, Tee)
  2. Tournament / round     (Tournament, Round, Foursome, Membership)
  3. Score entry            (ScoreSubmit — input validation)
  4. Scorecard              (per-player hole-by-hole view)
  5. Game result shapes     (Skins, Stableford, RedBall, etc.)
  6. Leaderboard            (aggregated round-level view)
"""

from rest_framework import serializers

from core.models import Player, Tee
from tournament.models import Tournament, Round, Foursome, FoursomeMembership
from scoring.models import HoleScore, StablefordResult, SkinsResult


# ===========================================================================
# 1. Core / reference data
# ===========================================================================

class PlayerSerializer(serializers.ModelSerializer):
    class Meta:
        model  = Player
        fields = ['id', 'name', 'handicap_index', 'is_phantom', 'email', 'phone']
        read_only_fields = ['id']


from core.models import Course

class CourseSerializer(serializers.ModelSerializer):
    class Meta:
        model  = Course
        fields = ['id', 'name', 'created_at']
        read_only_fields = ['id']


class TeeSerializer(serializers.ModelSerializer):
    course = CourseSerializer(read_only=True)

    class Meta:
        model  = Tee
        fields = ['id', 'course', 'tee_name', 'slope', 'course_rating', 'par', 'holes']
        read_only_fields = ['id']


# ===========================================================================
# 2. Tournament / round hierarchy
# ===========================================================================

class MembershipSerializer(serializers.ModelSerializer):
    player       = PlayerSerializer(read_only=True)
    player_id    = serializers.PrimaryKeyRelatedField(
        source='player', queryset=Player.objects.all(), write_only=True
    )
    tee          = TeeSerializer(read_only=True)

    class Meta:
        model  = FoursomeMembership
        fields = ['id', 'player', 'player_id', 'tee', 'course_handicap', 'playing_handicap']
        read_only_fields = ['id', 'tee', 'course_handicap', 'playing_handicap']


class FoursomeSerializer(serializers.ModelSerializer):
    memberships     = MembershipSerializer(many=True, read_only=True)
    pink_ball_order = serializers.JSONField(read_only=True)

    class Meta:
        model  = Foursome
        fields = ['id', 'group_number', 'has_phantom', 'pink_ball_order', 'memberships']
        read_only_fields = ['id']


class RoundSerializer(serializers.ModelSerializer):
    course   = CourseSerializer(read_only=True)
    foursomes = FoursomeSerializer(many=True, read_only=True)

    class Meta:
        model  = Round
        fields = [
            'id', 'round_number', 'date', 'course', 'status',
            'active_games', 'bet_unit', 'scramble_config', 'notes', 'foursomes',
        ]
        read_only_fields = ['id']


class RoundListSerializer(serializers.ModelSerializer):
    """Lightweight round serializer — no foursomes (used inside TournamentSerializer)."""
    course_name = serializers.CharField(source='course.name', read_only=True)

    class Meta:
        model  = Round
        fields = ['id', 'round_number', 'date', 'course_name', 'status', 'active_games', 'bet_unit']
        read_only_fields = ['id']


class TournamentSerializer(serializers.ModelSerializer):
    rounds = RoundListSerializer(many=True, read_only=True)

    class Meta:
        model  = Tournament
        fields = ['id', 'name', 'start_date', 'end_date', 'total_rounds',
                  'rounds_to_count', 'active_games', 'rounds']
        read_only_fields = ['id']


# ===========================================================================
# 3. Score entry — input validation
# ===========================================================================

class SingleScoreSerializer(serializers.Serializer):
    """One player's gross score for a hole."""
    player_id   = serializers.IntegerField()
    gross_score = serializers.IntegerField(min_value=1, max_value=20)


class ScoreSubmitSerializer(serializers.Serializer):
    """
    Submit scores for all players on one hole in a foursome.

    hole_number:    1–18
    scores:         list of {player_id, gross_score}
    pink_ball_lost: optional — set True if the designated player lost
                    the physical pink/red ball on this hole.
    """
    hole_number    = serializers.IntegerField(min_value=1, max_value=18)
    scores         = SingleScoreSerializer(many=True, min_length=1)
    pink_ball_lost = serializers.BooleanField(required=False, default=False)

    def validate_scores(self, value):
        player_ids = [s['player_id'] for s in value]
        if len(player_ids) != len(set(player_ids)):
            raise serializers.ValidationError("Duplicate player_id in scores list.")
        return value


class TournamentCreateSerializer(serializers.Serializer):
    """Create a new tournament."""
    name         = serializers.CharField(max_length=150)
    start_date   = serializers.DateField()
    active_games = serializers.ListField(child=serializers.CharField(), default=list)
    total_rounds = serializers.IntegerField(default=1, min_value=1)


class RoundCreateSerializer(serializers.Serializer):
    """Create a new round, optionally inside a tournament."""
    tournament_id = serializers.IntegerField(required=False, allow_null=True)
    course_id     = serializers.IntegerField()
    date          = serializers.DateField()
    bet_unit      = serializers.DecimalField(max_digits=6, decimal_places=2, default='1.00')
    active_games  = serializers.ListField(child=serializers.CharField(), default=list)
    round_number  = serializers.IntegerField(default=1, min_value=1)
    notes         = serializers.CharField(default='', allow_blank=True)


class PlayerTeeSelectionSerializer(serializers.Serializer):
    player_id = serializers.IntegerField()
    tee_id    = serializers.IntegerField()

class RoundSetupSerializer(serializers.Serializer):
    """
    Kick off a round: assign players to foursomes.
    players:            list of Player PKs and Tee PKs (max 16 for 4 foursomes)
    handicap_allowance: fraction of course handicap to apply (default 1.0)
    randomise:          shuffle players before grouping (default True)
    auto_setup_games:   if True, auto-configure Nassau/Sixes/MatchPlay teams
                        by handicap rank after the draw (default False)
    """
    players            = PlayerTeeSelectionSerializer(many=True, min_length=2, max_length=20)
    handicap_allowance = serializers.FloatField(default=1.0, min_value=0.0, max_value=1.0)
    randomise          = serializers.BooleanField(default=True)
    auto_setup_games   = serializers.BooleanField(default=False)


class NassauSetupSerializer(serializers.Serializer):
    """Assign fixed teams to a Nassau 9-9-18 game."""
    team1_player_ids = serializers.ListField(
        child=serializers.IntegerField(), min_length=1, max_length=2
    )
    team2_player_ids = serializers.ListField(
        child=serializers.IntegerField(), min_length=1, max_length=2
    )
    press_pct = serializers.FloatField(default=0.50, min_value=0.0, max_value=2.0)


class SixesSetupSerializer(serializers.Serializer):
    """
    Set up (or update) the Six's segments and teams for a foursome.
    segments is a list matching the services/sixes.py team_data format.
    """
    segments = serializers.ListField(child=serializers.DictField(), min_length=1, max_length=5)


# ===========================================================================
# 4. Scorecard output
# ===========================================================================

class HoleScoreSerializer(serializers.ModelSerializer):
    player_id   = serializers.IntegerField(source='player.id', read_only=True)
    player_name = serializers.CharField(source='player.name', read_only=True)

    class Meta:
        model  = HoleScore
        fields = [
            'player_id', 'player_name', 'hole_number',
            'gross_score', 'handicap_strokes', 'net_score', 'stableford_points',
        ]


class ScorecardHoleSerializer(serializers.Serializer):
    """One column (hole) of the scorecard — par, SI, and one row per player."""
    hole_number    = serializers.IntegerField()
    par            = serializers.IntegerField()
    stroke_index   = serializers.IntegerField()
    yards          = serializers.IntegerField(required=False)
    scores         = HoleScoreSerializer(many=True)


class ScorecardSerializer(serializers.Serializer):
    """
    Full 18-hole scorecard for a foursome.
    holes: list of ScorecardHole (one per hole, in order)
    totals: per-player summary {player_id, name, front_gross, back_gross,
            total_gross, front_net, back_net, total_net, total_stableford}
    """
    foursome_id  = serializers.IntegerField()
    group_number = serializers.IntegerField()
    holes        = ScorecardHoleSerializer(many=True)
    totals       = serializers.ListField(child=serializers.DictField())


# ===========================================================================
# 5. Per-game result shapes
# ===========================================================================

class SkinsHoleSerializer(serializers.Serializer):
    hole_number  = serializers.IntegerField()
    winner       = serializers.CharField(allow_null=True)
    skins_value  = serializers.IntegerField()
    is_carryover = serializers.BooleanField()


class SkinsSummarySerializer(serializers.Serializer):
    foursome_id  = serializers.IntegerField()
    group_number = serializers.IntegerField()
    holes        = SkinsHoleSerializer(many=True)
    totals       = serializers.ListField(child=serializers.DictField())
    # totals items: {player_id, name, skins_won, dollar_value}


class StablefordEntrySerializer(serializers.Serializer):
    player_id    = serializers.IntegerField()
    player_name  = serializers.CharField()
    total_points = serializers.IntegerField()
    rank         = serializers.IntegerField(allow_null=True)


class RedBallEntrySerializer(serializers.Serializer):
    rank              = serializers.IntegerField(allow_null=True)
    foursome_id       = serializers.IntegerField()
    group_number      = serializers.IntegerField()
    status            = serializers.CharField()   # "Survived 🏆" or "Lost on hole N"
    eliminated_on_hole = serializers.IntegerField(allow_null=True)
    total_net_score   = serializers.IntegerField(allow_null=True)


# ===========================================================================
# 6. Leaderboard — aggregated view for a round
# ===========================================================================

class LeaderboardSerializer(serializers.Serializer):
    """
    Top-level response for GET /api/rounds/{id}/leaderboard/
    Contains one entry per active game type.
    """
    round_id     = serializers.IntegerField()
    round_date   = serializers.DateField()
    course       = serializers.CharField()
    status       = serializers.CharField()
    active_games = serializers.ListField(child=serializers.CharField())
    games        = serializers.DictField()
    # games keyed by game_type value, each value is the summary dict
    # from the corresponding service's *_summary() function.
