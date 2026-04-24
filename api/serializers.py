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

from django.contrib.auth import get_user_model
from rest_framework import serializers

from core.models import Player, Tee
from tournament.models import Tournament, Round, Foursome, FoursomeMembership
from scoring.models import HoleScore, StablefordResult, SkinsResult

User = get_user_model()


# ===========================================================================
# 1. Core / reference data
# ===========================================================================

class PlayerSerializer(serializers.ModelSerializer):
    class Meta:
        model  = Player
        fields = ['id', 'name', 'short_name', 'handicap_index', 'is_phantom',
                  'email', 'phone', 'sex']
        read_only_fields = ['id']
        # short_name is writeable but optional — the Player.save() override
        # auto-fills it from initials when blank, so the mobile form can
        # either send a value or leave it out entirely.
        extra_kwargs = {
            'short_name': {'required': False, 'allow_blank': True},
        }


class PlayerCreateSerializer(serializers.ModelSerializer):
    """
    Used only when creating a new player via POST /api/players/.
    Accepts optional username + password to create a linked Django User
    account so the player can log in to the mobile app.
    If username/password are omitted the Player is created without a
    linked User (admin-only account, usable only via the admin panel).
    """
    username = serializers.CharField(required=False, allow_blank=True, write_only=True)
    password = serializers.CharField(required=False, allow_blank=True, write_only=True,
                                     style={'input_type': 'password'})

    class Meta:
        model  = Player
        fields = ['id', 'name', 'short_name', 'handicap_index',
                  'email', 'phone', 'sex', 'username', 'password']
        read_only_fields = ['id']
        extra_kwargs = {
            'short_name': {'required': False, 'allow_blank': True},
        }

    def validate(self, attrs):
        username = attrs.get('username', '').strip()
        password = attrs.get('password', '').strip()
        # Both or neither — don't allow partial credentials
        if bool(username) != bool(password):
            raise serializers.ValidationError(
                'Provide both username and password, or leave both blank.'
            )
        if username and User.objects.filter(username=username).exists():
            raise serializers.ValidationError(
                {'username': 'A user with that username already exists.'}
            )
        return attrs

    def create(self, validated_data):
        username = validated_data.pop('username', '').strip()
        password = validated_data.pop('password', '').strip()

        player = Player(**validated_data)
        player.save()

        if username and password:
            user = User.objects.create_user(
                username=username,
                password=password,
                email=validated_data.get('email', ''),
                first_name=validated_data.get('name', '').split()[0] if validated_data.get('name') else '',
            )
            player.user = user
            player.save(update_fields=['user'])

        return player


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
        fields = ['id', 'course', 'tee_name', 'slope', 'course_rating',
                  'par', 'holes', 'sex', 'sort_priority']
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
            'active_games', 'bet_unit', 'handicap_mode', 'net_percent',
            'scramble_config', 'notes', 'foursomes',
        ]
        read_only_fields = ['id']


class RoundListSerializer(serializers.ModelSerializer):
    """Lightweight round serializer — no foursomes (used inside TournamentSerializer)."""
    course_name = serializers.CharField(source='course.name', read_only=True)

    class Meta:
        model  = Round
        fields = ['id', 'round_number', 'date', 'course_name', 'status', 'active_games', 'bet_unit']
        read_only_fields = ['id']


class CasualRoundSummarySerializer(serializers.Serializer):
    """
    Lightweight summary of an in-progress casual round for the Casual Rounds list screen.
    Returned by GET /api/rounds/casual/.
    """
    id                  = serializers.IntegerField()
    date                = serializers.DateField()
    course_name         = serializers.CharField()
    status              = serializers.CharField()
    active_games        = serializers.ListField(child=serializers.CharField())
    bet_unit            = serializers.DecimalField(max_digits=6, decimal_places=2)
    current_hole        = serializers.IntegerField()   # 0 = not started
    created_by_player_id = serializers.IntegerField(allow_null=True)
    foursome_id         = serializers.IntegerField(allow_null=True)
    players             = serializers.ListField(child=serializers.DictField())


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
    bet_unit      = serializers.DecimalField(max_digits=6, decimal_places=2, default='0.00')
    active_games  = serializers.ListField(child=serializers.CharField(), default=list)
    round_number  = serializers.IntegerField(default=1, min_value=1)
    notes         = serializers.CharField(default='', allow_blank=True)
    handicap_mode = serializers.ChoiceField(
        choices=['gross', 'net', 'strokes_off'], default='net'
    )
    net_percent   = serializers.IntegerField(default=100, min_value=0, max_value=200)


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
    """
    Configure a Nassau 9-9-18 game for a foursome.

    team1/team2_player_ids: 1 or 2 player PKs each (1v1 or 2v2 best-ball).
    handicap_mode:          'net' | 'gross' | 'strokes_off'
    net_percent:            0–200, only meaningful when handicap_mode='net'
    press_mode:             'none' | 'manual' | 'auto' | 'both'
    press_unit:             dollar amount per press bet (separate from Round.bet_unit)
    """
    team1_player_ids = serializers.ListField(
        child=serializers.IntegerField(), min_length=1, max_length=2,
    )
    team2_player_ids = serializers.ListField(
        child=serializers.IntegerField(), min_length=1, max_length=2,
    )
    handicap_mode = serializers.ChoiceField(
        choices=['net', 'gross', 'strokes_off'],
        default='net',
    )
    net_percent = serializers.IntegerField(
        min_value=0, max_value=200, default=100,
    )
    press_mode = serializers.ChoiceField(
        choices=['none', 'manual', 'auto', 'both'],
        default='none',
    )
    press_unit = serializers.DecimalField(
        max_digits=8, decimal_places=2, default='0.00',
    )


class NassauPressSerializer(serializers.Serializer):
    """
    POST /api/foursomes/{id}/nassau/press/
    Called by the losing team to declare a manual press.

    start_hole: hole number (1–18) at which the press begins.
    """
    start_hole = serializers.IntegerField(min_value=1, max_value=18)


class SixesSetupSerializer(serializers.Serializer):
    """
    Set up (or update) the Six's segments and teams for a foursome.
    segments is a list matching the services/sixes.py team_data format.

    handicap_mode and net_percent are optional and default to full net
    (mode='net', net_percent=100) to preserve existing behavior for
    clients that haven't been updated yet.  'gross' ignores handicaps;
    'net' applies playing_handicap × (net_percent / 100) allocated by SI.
    """
    segments      = serializers.ListField(
                        child=serializers.DictField(),
                        min_length=1, max_length=5,
                    )
    handicap_mode = serializers.ChoiceField(
                        choices=['net', 'gross', 'strokes_off'],
                        default='net',
                    )
    net_percent   = serializers.IntegerField(
                        min_value=0, max_value=200, default=100,
                    )


class Points531SetupSerializer(serializers.Serializer):
    """
    Set up (or update) the Points 5-3-1 game for a foursome.

    No team data to validate — Points 5-3-1 is per-player, so the only
    knobs are the handicap policy the match is played under.  Mirrors
    SixesSetupSerializer for the handicap knobs so the mobile layer can
    reuse a single handicap-picker widget across both games.
    """
    handicap_mode = serializers.ChoiceField(
                        choices=['net', 'gross', 'strokes_off'],
                        default='net',
                    )
    net_percent   = serializers.IntegerField(
                        min_value=0, max_value=200, default=100,
                    )


class SkinsSetupSerializer(serializers.Serializer):
    """
    Set up (or update) the Skins game for a foursome.

    All knobs are optional and default to the most common configuration
    so the mobile client only needs to send the fields it cares about.
    """
    handicap_mode = serializers.ChoiceField(
                        choices=['net', 'gross', 'strokes_off'],
                        default='net',
                    )
    net_percent   = serializers.IntegerField(
                        min_value=0, max_value=200, default=100,
                    )
    carryover     = serializers.BooleanField(default=True)
    allow_junk    = serializers.BooleanField(default=False)


class IrishRumbleSetupSerializer(serializers.Serializer):
    """POST /api/rounds/{id}/irish-rumble/setup/"""
    handicap_mode = serializers.ChoiceField(
                        choices=['net', 'gross', 'strokes_off'],
                        default='net',
                    )
    net_percent   = serializers.IntegerField(
                        min_value=0, max_value=200, default=100,
                    )
    bet_unit      = serializers.DecimalField(
                        max_digits=6, decimal_places=2, default='1.00',
                    )


class LowNetSetupSerializer(serializers.Serializer):
    """POST /api/rounds/{id}/low-net/setup/"""
    handicap_mode = serializers.ChoiceField(
                        choices=['net', 'gross', 'strokes_off'],
                        default='net',
                    )
    net_percent   = serializers.IntegerField(
                        min_value=0, max_value=200, default=100,
                    )
    entry_fee     = serializers.DecimalField(
                        max_digits=8, decimal_places=2, default='0.00',
                    )
    payouts       = serializers.ListField(
                        child=serializers.DictField(),
                        default=list,
                        help_text=(
                            "[{'place': 1, 'amount': '60.00'}, "
                            "{'place': 2, 'amount': '30.00'}]"
                        ),
                    )


class PinkBallSetupSerializer(serializers.Serializer):
    """POST /api/rounds/{id}/pink-ball/setup/"""
    ball_color  = serializers.CharField(max_length=50, default='Pink')
    bet_unit    = serializers.DecimalField(
                      max_digits=8, decimal_places=2, default='1.00',
                  )
    places_paid = serializers.IntegerField(min_value=1, default=1)


class PinkBallOrderSerializer(serializers.Serializer):
    """POST /api/foursomes/{id}/pink-ball/order/"""
    order = serializers.ListField(
                child=serializers.IntegerField(),
                min_length=1,
                max_length=18,
                help_text='List of player PKs, one per hole (up to 18 entries).',
            )


class SkinsJunkEntrySerializer(serializers.Serializer):
    """One player's junk count for a single hole."""
    player_id  = serializers.IntegerField()
    junk_count = serializers.IntegerField(min_value=0, max_value=20)


class SkinsJunkSerializer(serializers.Serializer):
    """
    POST /api/foursomes/{id}/skins/junk/

    Upserts SkinsPlayerHoleResult rows for all players on a single hole.
    Rows with junk_count=0 are deleted so scorers can zero out a mistake.
    """
    hole_number  = serializers.IntegerField(min_value=1, max_value=18)
    junk_entries = SkinsJunkEntrySerializer(many=True, min_length=1)


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
