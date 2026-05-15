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
    memberships      = MembershipSerializer(many=True, read_only=True)
    pink_ball_order  = serializers.JSONField(read_only=True)
    active_games     = serializers.SerializerMethodField()
    configured_games = serializers.SerializerMethodField()

    # Map RyderCupFoursomeConfig.game_type → active_games key.
    # GameType enum values (strings) as stored in the DB.
    # 'singles' is pure 1-v-1 match play — it shares the match_play
    # bracket model and the same score-entry / summary endpoints.
    _CUP_GAME_TYPE_MAP = {
        'nassau'       : 'nassau',
        'irish_rumble' : 'irish_rumble',
        'match_play'   : 'match_play',
        'singles'      : 'match_play',
        'skins'        : 'skins',
    }

    def get_active_games(self, obj):
        """
        Return the effective active-games list for this foursome.

        Priority:
          1. Explicit per-foursome override (foursome.active_games non-empty),
             BUT if the stored list is ['match_play'] and this is a cup singles
             foursome (singles_nassau / singles_18), correct it to the proper key
             so Flutter can detect cup singles handicap mode correctly.
          2. Cup match assignment (RyderCupFoursomeConfig.game_type) — so the
             score-entry screen title shows only the game this group is playing,
             not the full round-level union of all cup game types.
          3. Empty list (caller falls back to round.active_games)
        """
        if obj.active_games:
            games = list(obj.active_games)
            # Fix legacy foursomes that were saved with 'match_play' instead of
            # the correct 'singles_nassau' or 'singles_18' key.
            if games == ['match_play']:
                try:
                    cup_cfg = obj.ryder_cup_foursome_config
                    from core.models import GameType as GT
                    if cup_cfg.game_type in (GT.SINGLES_NASSAU, GT.SINGLES_18):
                        return [cup_cfg.game_type]
                except Exception:
                    pass
            return games
        try:
            cup_cfg   = obj.ryder_cup_foursome_config
            game_key  = self._CUP_GAME_TYPE_MAP.get(cup_cfg.game_type, cup_cfg.game_type)
            return [game_key]
        except Exception:
            pass
        return []

    def get_configured_games(self, obj):
        """
        Return a list of game keys that have been explicitly set up for this
        foursome (game model row exists), independent of active_games.
        """
        games = []
        # OneToOne relationships — safe to check via hasattr
        for attr, key in [
            ('skins_game',         'skins'),
            ('nassau_game',        'nassau'),
            ('points_531_game',    'points_531'),
            ('three_person_match', 'three_person_match'),
        ]:
            try:
                getattr(obj, attr)
                games.append(key)
            except Exception:
                pass
        # FK relationships — check if any rows exist
        if obj.sixes_segments.exists():
            games.append('sixes')
        # match_play: configured as soon as any bracket row exists.
        # Previously this required payout_config != {}, but that caused the
        # score-entry screen to skip loading match play data when only an
        # entry fee (no payout split) was configured.  The "Set Up Bracket"
        # buttons on the round screen are gated on round.active_games, not
        # configured_games, so this change does not affect that display.
        if obj.match_play_brackets.exists():
            games.append('match_play')
        if obj.pink_ball_order:
            games.append('pink_ball')
        if obj.irish_rumble_results.exists():
            games.append('irish_rumble')
        # Cup match assignment counts as "configured" for its game type.
        try:
            cup_cfg  = obj.ryder_cup_foursome_config
            game_key = self._CUP_GAME_TYPE_MAP.get(cup_cfg.game_type, cup_cfg.game_type)
            if game_key not in games:
                games.append(game_key)
        except Exception:
            pass
        return games

    class Meta:
        model  = Foursome
        fields = [
            'id', 'group_number', 'has_phantom',
            'pink_ball_order', 'active_games', 'configured_games',
            'tee_time', 'memberships',
        ]
        read_only_fields = ['id']


class RoundSerializer(serializers.ModelSerializer):
    course         = CourseSerializer(read_only=True)
    foursomes      = FoursomeSerializer(many=True, read_only=True)
    is_cup_round   = serializers.SerializerMethodField()
    ir_balls_config = serializers.SerializerMethodField()

    def get_is_cup_round(self, obj):
        """True when this round has a Ryder Cup config (was set up via CupRoundSetupScreen)."""
        return hasattr(obj, 'ryder_cup_config')

    def get_ir_balls_config(self, obj):
        """
        Irish Rumble balls-per-segment config — list of
        {start_hole, end_hole, balls_to_count} dicts, or [] if not configured.
        Consumed by the score-entry screen to show "Best N of M" per hole.
        """
        try:
            return obj.irish_rumble_config.segments or []
        except Exception:
            return []

    class Meta:
        model  = Round
        fields = [
            'id', 'round_number', 'date', 'course', 'status',
            'active_games', 'game_point_values', 'bet_unit',
            'handicap_mode', 'net_percent', 'net_max_double_bogey',
            'scramble_config', 'notes', 'foursomes',
            'is_cup_round', 'ir_balls_config',
        ]
        read_only_fields = ['id']


class RoundListSerializer(serializers.ModelSerializer):
    """Lightweight round serializer — no foursomes (used inside TournamentSerializer)."""
    course_name = serializers.CharField(source='course.name', read_only=True)
    course_id   = serializers.IntegerField(source='course.id',   read_only=True)

    class Meta:
        model  = Round
        fields = [
            'id', 'round_number', 'date', 'course_id', 'course_name',
            'status', 'active_games', 'game_point_values', 'bet_unit',
        ]
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
    tournament_id     = serializers.IntegerField(required=False, allow_null=True)
    course_id         = serializers.IntegerField()
    date              = serializers.DateField()
    bet_unit          = serializers.DecimalField(max_digits=6, decimal_places=2, default='0.00')
    active_games      = serializers.ListField(child=serializers.CharField(), default=list)
    game_point_values = serializers.JSONField(required=False, default=dict)
    cup_group_counts  = serializers.JSONField(required=False, default=dict)
    round_number      = serializers.IntegerField(default=1, min_value=1)
    notes             = serializers.CharField(default='', allow_blank=True)
    handicap_mode     = serializers.ChoiceField(
        choices=['gross', 'net', 'strokes_off'], default='net'
    )
    net_percent       = serializers.IntegerField(default=100, min_value=0, max_value=200)
    net_max_double_bogey = serializers.BooleanField(default=False)


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
    active_games:       list of game keys to activate for this round — if
                        provided, overwrites Round.active_games before setup
    """
    players            = PlayerTeeSelectionSerializer(many=True, min_length=2, max_length=20)
    handicap_allowance = serializers.FloatField(default=1.0, min_value=0.0, max_value=1.0)
    randomise          = serializers.BooleanField(default=True)
    auto_setup_games   = serializers.BooleanField(default=False)
    active_games       = serializers.ListField(
                             child=serializers.CharField(max_length=50),
                             required=False, default=list)


class NassauSetupSerializer(serializers.Serializer):
    """
    Configure a Nassau 9-9-18 game for a foursome.

    team1/team2_player_ids: 1 or 2 player PKs each (1v1 or 2v2 best-ball).
    handicap_mode:          'net' | 'gross' | 'strokes_off'
    net_percent:            0–200, only meaningful when handicap_mode='net'
    press_mode:             'none' | 'manual' | 'auto' | 'both'
    press_unit:             dollar amount per press bet (separate from Round.bet_unit)
    variant:                'none' | 'tiebreak_2nd' | 'claremont'
                            tiebreak_2nd — 2nd best ball breaks tied holes (foursomes only)
                            claremont    — adds simultaneous 2-point bottom bet
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
    variant = serializers.ChoiceField(
        choices=['none', 'tiebreak_2nd', 'claremont'],
        default='none',
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


class ThreePersonMatchSetupSerializer(serializers.Serializer):
    """
    Set up (or replace) the Three-Person Match for a foursome.

    handicap_mode / net_percent control the score comparison in both phases.
    entry_fee     — per-player buy-in.
    payout_config — dict mapping place ('1st', '2nd', '3rd') → dollar amount.
    """
    handicap_mode = serializers.ChoiceField(
                        choices=['net', 'gross', 'strokes_off'],
                        default='net',
                    )
    net_percent   = serializers.IntegerField(
                        min_value=0, max_value=200, default=100,
                    )
    entry_fee     = serializers.DecimalField(
                        max_digits=7, decimal_places=2, default='0.00',
                    )
    payout_config = serializers.DictField(
                        child=serializers.FloatField(),
                        default=dict,
                        help_text="{'1st': 48.00, '2nd': 24.00, '3rd': 0.00}",
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


class LowNetSetupSerializer(serializers.Serializer):
    """POST /api/rounds/{id}/low-net/setup/"""
    handicap_mode       = serializers.ChoiceField(
                              choices=['net', 'gross', 'strokes_off'],
                              default='net',
                          )
    net_percent         = serializers.IntegerField(
                              min_value=0, max_value=200, default=100,
                          )
    entry_fee           = serializers.DecimalField(
                              max_digits=8, decimal_places=2, default='0.00',
                          )
    payouts             = serializers.ListField(
                              child=serializers.DictField(),
                              default=list,
                              help_text=(
                                  "[{'place': 1, 'amount': '60.00'}, "
                                  "{'place': 2, 'amount': '30.00'}]"
                              ),
                          )
    excluded_player_ids = serializers.ListField(
                              child=serializers.IntegerField(),
                              default=list,
                              help_text=(
                                  "Player IDs ineligible for prizes "
                                  "(e.g. championship Low Net placers)."
                              ),
                          )


class PinkBallSetupSerializer(serializers.Serializer):
    """POST /api/rounds/{id}/pink-ball/setup/"""
    ball_color = serializers.CharField(max_length=50, default='Pink')
    entry_fee  = serializers.DecimalField(
                     max_digits=8, decimal_places=2, default='0.00',
                 )
    payouts    = serializers.ListField(
                     child=serializers.DictField(),
                     default=list,
                     help_text=(
                         "[{'place': 1, 'amount': '60.00'}, "
                         "{'place': 2, 'amount': '30.00'}]"
                     ),
                 )


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


# ===========================================================================
# 7. Team Tournament (Ryder Cup style)
# ===========================================================================

# ── 7a. Setup inputs ─────────────────────────────────────────────────────────

class TeamSetupSerializer(serializers.Serializer):
    """
    One team definition inside TeamTournamentSetupSerializer.
    team_number is 1-based and must be unique within the tournament.
    """
    team_number = serializers.IntegerField(min_value=1)
    name        = serializers.CharField(max_length=100)
    colour      = serializers.CharField(max_length=50,  required=False, allow_blank=True, default='')
    short_code  = serializers.CharField(max_length=5,   required=False, allow_blank=True, default='')


class TeamTournamentSetupSerializer(serializers.Serializer):
    """
    POST /api/tournaments/<pk>/team-tournament/setup/

    Creates the TeamTournament and its initial empty team rosters.
    Players are added separately via the /teams/<team_pk>/players/ endpoint.

    Body:
        {
          "cup_name"       : "Bandon Cup 2026",  // editable display name
          "players_per_team": 6,
          "teams": [
            {"team_number": 1, "name": "Team USA",    "colour": "Blue", "short_code": "USA"},
            {"team_number": 2, "name": "Team Europe",  "colour": "Red",  "short_code": "EUR"}
          ]
        }
    """
    cup_name         = serializers.CharField(max_length=100, required=False, default='Ryder Cup')
    players_per_team = serializers.IntegerField(min_value=1, default=6)
    teams            = TeamSetupSerializer(many=True)

    def validate_teams(self, value):
        numbers = [t['team_number'] for t in value]
        if len(numbers) != len(set(numbers)):
            raise serializers.ValidationError('team_number values must be unique.')
        if len(value) < 2:
            raise serializers.ValidationError('At least 2 teams are required.')
        return value


class TeamPlayerSerializer(serializers.Serializer):
    """
    POST /api/tournaments/<pk>/team-tournament/teams/<team_pk>/players/
    Body: {"player_id": 5}
    """
    player_id = serializers.IntegerField()


class FoursomeRyderConfigSerializer(serializers.Serializer):
    """
    One foursome's Ryder Cup game config inside RyderCupRoundSetupSerializer.
    """
    foursome_id      = serializers.IntegerField()
    game_type        = serializers.CharField(max_length=30)
    team1_id         = serializers.IntegerField(required=False, allow_null=True)
    team2_id         = serializers.IntegerField(required=False, allow_null=True)
    point_value      = serializers.DecimalField(
                           max_digits=5, decimal_places=2,
                           required=False, default='1.00'
                       )
    singles_matchups = serializers.ListField(
                           child=serializers.DictField(),
                           required=False, default=list
                       )


class IrishRumblePairingSerializer(serializers.Serializer):
    """
    Cross-foursome head-to-head Irish Rumble pairing.
    Each foursome is a homogeneous team (all players on the same Ryder Cup team).
    """
    foursome_a_id = serializers.IntegerField()
    foursome_b_id = serializers.IntegerField()
    team_a_id     = serializers.IntegerField()
    team_b_id     = serializers.IntegerField()


class RyderCupRoundSetupSerializer(serializers.Serializer):
    """
    POST /api/rounds/<pk>/ryder-cup/setup/

    Configures Ryder Cup scoring for a round.  Creates:
      - RyderCupRoundConfig (point values + multiplier)
      - RyderCupFoursomeConfig per foursome listed in `foursomes`
      - RyderCupIrishRumblePairing per entry in `irish_rumble_pairings`

    Body:
        {
          "nassau_point_value"  : 1.0,
          "point_multiplier"    : 1.0,
          "notes"               : "Four-ball Nassau — Round 1",
          "foursomes": [
            {"foursome_id": 1, "game_type": "nassau",  "team1_id": 1, "team2_id": 2},
            {"foursome_id": 2, "game_type": "nassau",  "team1_id": 1, "team2_id": 2},
            {"foursome_id": 3, "game_type": "nassau",  "team1_id": 1, "team2_id": 2}
          ],
          "irish_rumble_pairings": []
        }

    For an Irish Rumble round, leave `foursomes` empty (or populate with the
    singles group only) and fill `irish_rumble_pairings`:
        {
          "foursomes": [
            {"foursome_id": 3, "game_type": "nassau", "team1_id": 1, "team2_id": 2}
          ],
          "irish_rumble_pairings": [
            {"foursome_a_id": 1, "foursome_b_id": 2, "team_a_id": 1, "team_b_id": 2}
          ]
        }
    """
    nassau_point_value   = serializers.DecimalField(
                               max_digits=5, decimal_places=2,
                               required=False, default='1.00'
                           )
    point_multiplier     = serializers.DecimalField(
                               max_digits=5, decimal_places=2,
                               required=False, default='1.00'
                           )
    notes                = serializers.CharField(required=False, allow_blank=True, default='')
    foursomes            = FoursomeRyderConfigSerializer(many=True, required=False, default=list)
    irish_rumble_pairings = IrishRumblePairingSerializer(many=True, required=False, default=list)


class QuotaPairingSerializer(serializers.Serializer):
    """
    One 1v1 pairing inside QuotaNassauSetupSerializer.
    player1_quota / player2_quota = 36 − course_handicap_index.
    If omitted, the setup view calculates them from the stored FoursomeMembership.
    """
    player1_id    = serializers.IntegerField()
    player2_id    = serializers.IntegerField()
    player1_quota = serializers.IntegerField(required=False, allow_null=True)
    player2_quota = serializers.IntegerField(required=False, allow_null=True)


class QuotaNassauSetupSerializer(serializers.Serializer):
    """
    POST /api/foursomes/<pk>/quota-nassau/setup/

    Creates the QuotaNassauGame and its 1v1 QuotaNassauMatch rows.
    If player_quota values are omitted the view auto-calculates them
    from the stored course_handicap_index on FoursomeMembership.

    Body (explicit quotas):
        {
          "pairings": [
            {"player1_id": 1, "player2_id": 4, "player1_quota": 18, "player2_quota": 22},
            {"player1_id": 2, "player2_id": 5, "player1_quota": 24, "player2_quota": 16}
          ]
        }

    Body (auto-calculate quotas from handicaps):
        {
          "pairings": [
            {"player1_id": 1, "player2_id": 4},
            {"player1_id": 2, "player2_id": 5}
          ]
        }
    """
    pairings = QuotaPairingSerializer(many=True)

    def validate_pairings(self, value):
        if not value:
            raise serializers.ValidationError('At least one pairing is required.')
        for p in value:
            if p['player1_id'] == p['player2_id']:
                raise serializers.ValidationError('player1 and player2 must be different players.')
        return value


# ---------------------------------------------------------------------------
# Tee-time bulk update
# ---------------------------------------------------------------------------

class TeeTimeEntrySerializer(serializers.Serializer):
    """One entry in a bulk tee-time update: {group_number, tee_time}."""
    group_number = serializers.IntegerField(min_value=1)
    tee_time     = serializers.TimeField(
        allow_null=True,
        help_text='HH:MM or HH:MM:SS.  Null clears the tee time.',
    )


class TeeTimeBulkSerializer(serializers.Serializer):
    """
    Body for PATCH /api/rounds/<id>/tee-times/

    [{"group_number": 1, "tee_time": "08:00"},
     {"group_number": 2, "tee_time": "08:10"}, ...]
    """
    tee_times = TeeTimeEntrySerializer(many=True)
