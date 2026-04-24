from django.db import models
from django.core.validators import MinValueValidator, MaxValueValidator

from core.models import MatchStatus, TeamSelectMethod, HandicapMode, Player
from tournament.models import Round, Foursome


# ---------------------------------------------------------------------------
# SIX'S (3 × 6-hole rotating-team best ball match play within foursome)
# ---------------------------------------------------------------------------

class SixesSegment(models.Model):
    """
    One 6-hole block of the Six's game. Standard play has 3 segments
    (holes 1-6, 7-12, 13-18), but a segment can end early if a team wins
    before the 6th hole — the leftover holes form a 4th (extra) match.

    segment_number: 1, 2, 3; extra matches get segment_number=4+.
    is_extra: True for the bonus match created from leftover holes.
    status: 'pending', 'in_progress', 'complete', 'halved'.

    Team formation per segment:
      - Segment 1: long drive winner picks / long vs short drive pairing
      - Segment 2: random draw
      - Segment 3: remaining combination
      - Extra match: loser of previous match chooses partner (loser_choice)
    """
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='sixes_segments')
    segment_number      = models.PositiveSmallIntegerField()
    start_hole          = models.PositiveSmallIntegerField()
    end_hole            = models.PositiveSmallIntegerField()
    status              = models.CharField(max_length=20, choices=MatchStatus.choices, default=MatchStatus.PENDING)
    is_extra            = models.BooleanField(
                            default=False,
                            help_text="True for the 4th match created from leftover holes after an early finish."
                        )
    # Handicap mode is per-foursome (the user picks it once when setting up Sixes).
    # We persist the value on every segment of the same foursome for simplicity;
    # setup_sixes keeps them in sync.  Gross mode ignores handicaps entirely;
    # Net mode uses playing_handicap × (net_percent / 100) allocated by SI.
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=HandicapMode.choices,
                            default=HandicapMode.NET,
                            help_text="How per-hole scores are adjusted for this match.",
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            validators=[MinValueValidator(0), MaxValueValidator(200)],
                            help_text="Percentage of playing handicap applied when handicap_mode='net'.",
                        )
    created_at          = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['segment_number', 'start_hole']

    def __str__(self):
        extra = ' (extra)' if self.is_extra else ''
        return f"Segment {self.segment_number}{extra} (holes {self.start_hole}–{self.end_hole}) — {self.foursome}"


class SixesTeam(models.Model):
    """
    One of the two teams in a SixesSegment.
    team_select_method records how this team was formed.
    is_winner is set when the segment completes.
    """
    segment             = models.ForeignKey(SixesSegment, on_delete=models.CASCADE, related_name='teams')
    players             = models.ManyToManyField(Player, related_name='sixes_teams')
    team_number         = models.PositiveSmallIntegerField()  # 1 or 2
    team_select_method  = models.CharField(max_length=20, choices=TeamSelectMethod.choices)
    is_winner           = models.BooleanField(default=False)

    def __str__(self):
        return f"Team {self.team_number} — {self.segment}"


class SixesHoleResult(models.Model):
    """
    Best ball result for one hole within a SixesSegment.
    winning_team is null on a halve.
    holes_up_after: running match play margin after this hole
        (positive = team1 leading, negative = team2 leading).
    """
    segment             = models.ForeignKey(SixesSegment, on_delete=models.CASCADE, related_name='hole_results')
    hole_number         = models.PositiveSmallIntegerField()
    team1_best_net      = models.SmallIntegerField(null=True, blank=True)
    team2_best_net      = models.SmallIntegerField(null=True, blank=True)
    winning_team        = models.ForeignKey(
                            SixesTeam, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='holes_won'
                        )
    holes_up_after      = models.SmallIntegerField(
                            default=0,
                            help_text="Running margin after this hole: +ve = team1 leading."
                        )

    class Meta:
        unique_together = ('segment', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.segment}"


# ---------------------------------------------------------------------------
# POINTS 5-3-1 (3-player hole-by-hole points, casual-round only)
# ---------------------------------------------------------------------------

class Points531Game(models.Model):
    """
    The Points 5-3-1 game for one Foursome.  Designed for exactly three
    real players (phantoms are ignored).  On every hole the lowest net
    score receives 5 points, 2nd 3 points, 3rd 1 point, with ties split
    evenly so each hole always pays out 9 points in total.

    Settlement follows a "par" of 3 points per hole (average points
    awarded to each of the 3 players): money for a player = (their
    points − 3 × holes_played) × bet_unit.  Across the 3 players this
    sums to zero.

    handicap_mode / net_percent are stored per-game so the match travels
    with its own handicap policy and supports Net (with percentage),
    Gross, and Strokes-Off-Low.  We keep the API surface identical to
    Sixes for UI reuse.
    """
    foursome            = models.OneToOneField(
                            Foursome, on_delete=models.CASCADE,
                            related_name='points_531_game',
                        )
    status              = models.CharField(
                            max_length=20,
                            choices=MatchStatus.choices,
                            default=MatchStatus.PENDING,
                        )
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=HandicapMode.choices,
                            default=HandicapMode.NET,
                            help_text="How per-hole scores are adjusted for ranking.",
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            validators=[MinValueValidator(0), MaxValueValidator(200)],
                            help_text="Percentage of playing handicap applied when handicap_mode='net'.",
                        )
    created_at          = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Points 5-3-1 — Group {self.foursome.group_number}"


class Points531PlayerHoleResult(models.Model):
    """
    One row per (game, player, hole) recording the net score used for
    ranking and the points awarded.  Points are stored as a Decimal to
    accommodate tie-splits (e.g. 4.0 when two players tie for first:
    (5 + 3) / 2 = 4).  holes where the player has no gross yet are
    simply absent — calculate_points_531 only creates rows for holes
    where all three real players have reported a score, so the hole's
    9-point total invariant is always preserved on persisted rows.
    """
    game                = models.ForeignKey(
                            Points531Game, on_delete=models.CASCADE,
                            related_name='hole_results',
                        )
    player              = models.ForeignKey(
                            Player, on_delete=models.CASCADE,
                            related_name='points_531_hole_results',
                        )
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    net_score           = models.SmallIntegerField(
                            help_text="The score used for ranking (net/gross/SO-adjusted, per game.handicap_mode).",
                        )
    points_awarded      = models.DecimalField(
                            max_digits=4, decimal_places=2,
                            help_text="Per-hole points — 5/3/1 by rank, tie-split so sum per hole is always 9.",
                        )

    class Meta:
        unique_together = ('game', 'player', 'hole_number')
        ordering        = ['hole_number', '-points_awarded']

    def __str__(self):
        return (f"Hole {self.hole_number} — {self.player.name} — "
                f"{self.points_awarded}pt ({self.game})")


# ---------------------------------------------------------------------------
# SKINS (per-hole individual contest, 2–4 real players, no phantoms)
# ---------------------------------------------------------------------------

class SkinsGame(models.Model):
    """
    The Skins game for one Foursome.  Designed for 2–4 real players
    (phantoms excluded).  On each hole the player with the best
    score-to-compare (net / gross / strokes-off) wins a skin outright.
    A tie either carries the skin to the next hole (carryover=True) or
    kills it (carryover=False).  Unresolved carries at the end of hole
    18 are voided — the denominator in the pool split simply shrinks.

    Optional junk skins (birdies, sandies, chip-ins, etc.) are manually
    entered per player per hole as an integer count when allow_junk=True.

    Settlement: each player chips in 1 × Round.bet_unit.  The pool is
    divided proportionally among players based on total skins won
    (regular + junk) out of the grand total awarded.  Zero-skin players
    receive nothing.
    """
    foursome        = models.OneToOneField(
                        Foursome, on_delete=models.CASCADE,
                        related_name='skins_game',
                    )
    status          = models.CharField(
                        max_length=20,
                        choices=MatchStatus.choices,
                        default=MatchStatus.PENDING,
                    )
    handicap_mode   = models.CharField(
                        max_length=20,
                        choices=HandicapMode.choices,
                        default=HandicapMode.NET,
                        help_text="How per-hole scores are adjusted for ranking.",
                    )
    net_percent     = models.PositiveSmallIntegerField(
                        default=100,
                        validators=[MinValueValidator(0), MaxValueValidator(200)],
                        help_text="Percentage of playing handicap applied when "
                                  "handicap_mode='net'.",
                    )
    carryover       = models.BooleanField(
                        default=True,
                        help_text="If True a tied hole carries its pot to the next "
                                  "hole; if False the tied skin is voided.",
                    )
    allow_junk      = models.BooleanField(
                        default=False,
                        help_text="If True the entry screen shows a per-player "
                                  "junk-skin counter (birdies, sandies, chip-ins, etc.).",
                    )
    created_at      = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Skins — Group {self.foursome.group_number}"


class SkinsHoleResult(models.Model):
    """
    Calculated per-hole outcome for a SkinsGame.  One row per hole for
    which all real players have submitted a gross score.

    winner:      null on a carry or dead hole.
    skins_value: skins pot at the time of resolution.
                   - Won hole:  total skins awarded to winner (≥1 with carryover).
                   - Carry hole: current pot being carried (≥1).
                   - Dead hole (no-carryover tie): always 1 (the skin that died).
    is_carry:    True only when the skin carries (tie + carryover=True).
                 A null winner + is_carry=False means the skin was killed.
    """
    game            = models.ForeignKey(
                        SkinsGame, on_delete=models.CASCADE,
                        related_name='hole_results',
                    )
    hole_number     = models.PositiveSmallIntegerField(
                        validators=[MinValueValidator(1), MaxValueValidator(18)]
                    )
    winner          = models.ForeignKey(
                        Player, on_delete=models.SET_NULL,
                        null=True, blank=True,
                        related_name='skins_holes_won',
                    )
    skins_value     = models.PositiveSmallIntegerField(default=1)
    is_carry        = models.BooleanField(default=False)

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        if self.winner:
            return (f"Hole {self.hole_number} — {self.winner.name} "
                    f"wins {self.skins_value} skin(s)")
        tag = 'carry' if self.is_carry else 'dead'
        return f"Hole {self.hole_number} — {tag} ({self.skins_value})"


class SkinsPlayerHoleResult(models.Model):
    """
    Manually entered junk-skin counts per player per hole.  Only rows
    with junk_count > 0 need to be persisted; the calculator includes
    these in the pool split alongside the regular per-hole skins.
    """
    game            = models.ForeignKey(
                        SkinsGame, on_delete=models.CASCADE,
                        related_name='junk_results',
                    )
    player          = models.ForeignKey(
                        Player, on_delete=models.CASCADE,
                        related_name='skins_junk_results',
                    )
    hole_number     = models.PositiveSmallIntegerField(
                        validators=[MinValueValidator(1), MaxValueValidator(18)]
                    )
    junk_count      = models.PositiveSmallIntegerField(
                        default=0,
                        help_text="Number of junk skins (birdies, sandies, etc.) "
                                  "earned by this player on this hole.",
                    )

    class Meta:
        unique_together = ('game', 'player', 'hole_number')
        ordering        = ['hole_number', 'player_id']

    def __str__(self):
        return (f"Junk ×{self.junk_count} — {self.player.name} "
                f"hole {self.hole_number} ({self.game})")


# ---------------------------------------------------------------------------
# NASSAU (9-9-18 fixed-team best ball match play with auto-press)
# ---------------------------------------------------------------------------

NASSAU_RESULT_CHOICES = [
    ('team1',  'Team 1'),
    ('team2',  'Team 2'),
    ('halved', 'Halved'),
]

NASSAU_PRESS_MODE_CHOICES = [
    ('none',   'No presses'),
    ('manual', 'Manual — losing team calls it, winning team must accept'),
    ('auto',   'Auto at 2-down'),
    ('both',   'Manual + auto at 2-down'),
]

NASSAU_PRESS_TYPE_CHOICES = [
    ('manual', 'Manual'),
    ('auto',   'Auto'),
]


class NassauGame(models.Model):
    """
    The Nassau game for one Foursome. Teams are fixed for all 18 holes.

    Three simultaneous bets each worth Round.bet_unit:
      - Front 9  (holes 1–9)
      - Back 9   (holes 10–18)
      - Overall  (all 18)

    Tied 9-hole bets are a push — no money changes hands for that segment.

    Press bets:
      - press_unit: explicit dollar amount per press (separate from bet_unit)
      - press_mode: none / manual / auto / both
        Manual presses: losing team calls it any time; winning team must accept
        (cannot decline).  Auto presses: fire automatically when the losing
        team falls 2 holes down within a nine.  Both modes can coexist.

    Handicap modes: net (with net_percent allowance), gross, strokes_off_low.

    front9_result / back9_result / overall_result: set when each concludes
    ('team1', 'team2', or 'halved').
    """
    foursome            = models.OneToOneField(Foursome, on_delete=models.CASCADE, related_name='nassau_game')
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=HandicapMode.choices,
                            default=HandicapMode.NET,
                            help_text="How individual scores are adjusted before best-ball comparison.",
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            validators=[MinValueValidator(0), MaxValueValidator(200)],
                            help_text="Percentage of playing handicap applied when handicap_mode='net'.",
                        )
    press_mode          = models.CharField(
                            max_length=10,
                            choices=NASSAU_PRESS_MODE_CHOICES,
                            default='none',
                        )
    press_unit          = models.DecimalField(
                            max_digits=8, decimal_places=2, default='0.00',
                            help_text="Dollar amount per press bet (separate from Round.bet_unit).",
                        )
    front9_result       = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    back9_result        = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    overall_result      = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    status              = models.CharField(max_length=20, choices=MatchStatus.choices, default=MatchStatus.PENDING)

    def __str__(self):
        return f"Nassau — Group {self.foursome.group_number}"


class NassauTeam(models.Model):
    """
    One of the two teams in a NassauGame.
    team_number: 1 or 2.
    Players are assigned once and fixed for the whole round.
    """
    game                = models.ForeignKey(NassauGame, on_delete=models.CASCADE, related_name='teams')
    players             = models.ManyToManyField(Player, related_name='nassau_teams')
    team_number         = models.PositiveSmallIntegerField()   # 1 or 2

    def __str__(self):
        return f"Team {self.team_number} — {self.game}"


class NassauHoleScore(models.Model):
    """
    Best ball score for each team on each hole of a NassauGame.
    winner: 'team1', 'team2', or 'halved'. Null if not yet played.
    holes_up_after: cumulative 18-hole match margin
        (positive = team1 leading, negative = team2 leading).
    front9_up_after / back9_up_after track the 9-hole sub-bets separately.
    """
    game                = models.ForeignKey(NassauGame, on_delete=models.CASCADE, related_name='hole_scores')
    hole_number         = models.PositiveSmallIntegerField()
    team1_best_net      = models.SmallIntegerField(null=True, blank=True)
    team2_best_net      = models.SmallIntegerField(null=True, blank=True)
    winner              = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    # Running margins within each nine (for press trigger detection)
    front9_up_after     = models.SmallIntegerField(
                            null=True, blank=True,
                            help_text="Running front-9 margin after this hole (holes 1-9 only)."
                        )
    back9_up_after      = models.SmallIntegerField(
                            null=True, blank=True,
                            help_text="Running back-9 margin after this hole (holes 10-18 only)."
                        )
    overall_up_after    = models.SmallIntegerField(
                            null=True, blank=True,
                            help_text="Running overall margin after this hole (all 18)."
                        )

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.game}"


class NassauPress(models.Model):
    """
    A press bet within a NassauGame — either auto-triggered (2-down) or
    manually called by the losing team.

    nine:             'front' (holes 1-9) or 'back' (holes 10-18)
    press_type:       'auto' (2-down trigger) or 'manual' (losing team)
    triggered_on_hole: hole after which the press was called (press starts
                       on start_hole = triggered_on_hole + 1)
    start_hole:       first hole counted in this press
    end_hole:         last hole of that nine (9 for front, 18 for back)
    result:           set when the press concludes (None while active)
    holes_up:         final margin: +ve = team1 won, -ve = team2 won, 0 = halved
    """
    game                = models.ForeignKey(NassauGame, on_delete=models.CASCADE, related_name='presses')
    nine                = models.CharField(
                            max_length=5,
                            choices=[('front', 'Front 9'), ('back', 'Back 9')]
                        )
    press_type          = models.CharField(
                            max_length=10,
                            choices=NASSAU_PRESS_TYPE_CHOICES,
                            default='auto',
                        )
    triggered_on_hole   = models.PositiveSmallIntegerField()
    start_hole          = models.PositiveSmallIntegerField()
    end_hole            = models.PositiveSmallIntegerField()
    result              = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    holes_up            = models.SmallIntegerField(
                            null=True, blank=True,
                            help_text="Final margin of this press: +ve = team1 won."
                        )

    class Meta:
        ordering = ['triggered_on_hole']

    def __str__(self):
        return f"{self.get_press_type_display()} press hole {self.triggered_on_hole} ({self.nine}) — {self.game}"


# ---------------------------------------------------------------------------
# IRISH RUMBLE (all foursomes vs each other, best N balls per segment)
# ---------------------------------------------------------------------------

class IrishRumbleConfig(models.Model):
    """
    Defines the Irish Rumble structure for a round.
    segments is a JSON list defining each segment:
        [
          {"start_hole": 1,  "end_hole": 6,  "balls_to_count": 1},
          {"start_hole": 7,  "end_hole": 12, "balls_to_count": 2},
          {"start_hole": 13, "end_hole": 17, "balls_to_count": 3},
          {"start_hole": 18, "end_hole": 18, "balls_to_count": 4},
        ]
    For a 3-some foursome, balls_to_count is automatically capped at
    the number of real players in that group (phantom excluded from count).

    A double-bogey cap (max 2 over par per hole) is always applied before
    taking the best-N scores — this is the Stableford-style damage limiter.

    For strokes_off mode, the low handicap reference is the lowest
    playing_handicap across ALL foursomes in the round (not just within
    each group), so every player competes from the same baseline.
    """
    round               = models.OneToOneField(Round, on_delete=models.CASCADE, related_name='irish_rumble_config')
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=HandicapMode.choices,
                            default=HandicapMode.NET,
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            help_text="Percentage of playing handicap applied when handicap_mode='net'.",
                        )
    bet_unit            = models.DecimalField(
                            max_digits=6, decimal_places=2, default=1.00,
                            help_text="Dollar value of the Irish Rumble bet (winner-take-all).",
                        )
    segments            = models.JSONField(
                            help_text="List of segment dicts with start_hole, end_hole, balls_to_count."
                        )

    def balls_for_group(self, segment_index, player_count):
        """
        Returns actual balls to count for a group, capped by real player count.
        segment_index is 0-based.
        """
        configured = self.segments[segment_index]['balls_to_count']
        return min(configured, player_count)

    def __str__(self):
        return f"Irish Rumble config — {self.round}"


class IrishRumbleSegmentResult(models.Model):
    """
    The total net score for a Foursome in one Irish Rumble segment.
    score is the sum of the best N net scores across the segment holes.
    rank is set when all foursomes have completed the segment.
    """
    round               = models.ForeignKey(Round, on_delete=models.CASCADE, related_name='irish_rumble_results')
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='irish_rumble_results')
    segment_index       = models.PositiveSmallIntegerField()  # 0-based, matches IrishRumbleConfig.segments
    balls_counted       = models.PositiveSmallIntegerField()
    total_net_score     = models.SmallIntegerField(null=True, blank=True)
    rank                = models.PositiveSmallIntegerField(null=True, blank=True)

    class Meta:
        unique_together = ('round', 'foursome', 'segment_index')

    def __str__(self):
        return f"Group {self.foursome.group_number} — Segment {self.segment_index} — {self.total_net_score}"


# ---------------------------------------------------------------------------
# LOW NET ROUND CONFIG (individual low-net game within a round)
# ---------------------------------------------------------------------------

class LowNetRoundConfig(models.Model):
    """
    Configuration for the Low Net individual game within a round.

    A double-bogey cap (max 2 over par per hole) is always applied.
    For strokes_off mode, the low handicap reference is the lowest
    playing_handicap across ALL foursomes in the round.

    payouts is a JSON list defining the payout structure:
        [{"place": 1, "amount": 60.00}, {"place": 2, "amount": 30.00}, ...]
    entry_fee is collected from each player; total pool is distributed
    per the payouts list.
    """
    round               = models.OneToOneField(Round, on_delete=models.CASCADE, related_name='low_net_config')
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=HandicapMode.choices,
                            default=HandicapMode.NET,
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            help_text="Percentage of playing handicap applied when handicap_mode='net'.",
                        )
    entry_fee           = models.DecimalField(
                            max_digits=8, decimal_places=2, default=0.00,
                            help_text="Entry fee per player.",
                        )
    payouts             = models.JSONField(
                            default=list,
                            help_text=(
                                "Payout per finishing place. "
                                "Example: [{'place': 1, 'amount': 60.00}, "
                                "{'place': 2, 'amount': 30.00}]"
                            ),
                        )

    def __str__(self):
        return f"Low Net config — {self.round}"


# ---------------------------------------------------------------------------
# PINK BALL CONFIG (round-level settings for the survivor pool game)
# ---------------------------------------------------------------------------

class PinkBallConfig(models.Model):
    """
    Round-level configuration for the Pink Ball survivor pool.

    ball_color  : the colour name shown in the UI ("Pink", "Red", "Yellow", …)
    bet_unit    : entry fee per foursome; total pool = bet_unit × num_groups.
    places_paid : number of finishing places that receive a payout (default 1 = winner takes all).
                  Pool is split equally among paid places, then further split among tied groups
                  within each place.
    """
    round       = models.OneToOneField(
                      Round, on_delete=models.CASCADE,
                      related_name='pink_ball_config'
                  )
    ball_color  = models.CharField(max_length=50, default='Pink')
    bet_unit    = models.DecimalField(max_digits=8, decimal_places=2, default=1.00)
    places_paid = models.PositiveSmallIntegerField(default=1)

    class Meta:
        verbose_name = 'Pink Ball Config'

    def __str__(self):
        return f"Pink Ball config ({self.ball_color}, ${self.bet_unit}, {self.places_paid}P) — {self.round}"


# ---------------------------------------------------------------------------
# RED BALL / PINK BALL (survivor pool — last ball standing wins)
# ---------------------------------------------------------------------------

class PinkBallHoleResult(models.Model):
    """
    Tracks the red/pink ball for one foursome on one hole.

    Survival rules:
    - The designated player (from Foursome.pink_ball_order) must carry the
      physical ball on their assigned hole.
    - If the ball is lost (OB, water, unplayable and not recovered), ball_lost
      is set to True and that foursome is eliminated from the contest.
    - net_score records the designated player's net score while the ball is
      still alive (used for tiebreaking among survivors).
    - is_winner is set True on the final hole for the winning foursome.
    """
    round               = models.ForeignKey(Round, on_delete=models.CASCADE, related_name='pink_ball_results')
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='pink_ball_results')
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    pink_ball_player    = models.ForeignKey(Player, on_delete=models.PROTECT, related_name='pink_ball_holes')
    net_score           = models.PositiveSmallIntegerField(null=True, blank=True)
    ball_lost           = models.BooleanField(
                            default=False,
                            help_text="True if the physical ball was lost on this hole, eliminating this foursome."
                        )
    is_winner           = models.BooleanField(default=False)

    class Meta:
        unique_together = ('round', 'foursome', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        status = ' ❌ LOST' if self.ball_lost else ''
        return f"Red Ball — Group {self.foursome.group_number} — Hole {self.hole_number} — {self.net_score}{status}"


class PinkBallResult(models.Model):
    """
    Round-level red ball result for one foursome.

    eliminated_on_hole: the hole number where the ball was lost.
                        Null means the foursome survived all 18 holes.
    total_net_score:    sum of the designated player's net scores across all
                        holes played while the ball was alive. Used to rank
                        survivors and as a secondary tiebreaker for eliminated
                        foursomes that went out on the same hole.
    rank:               1 = winner. Foursomes that survive rank above those
                        that don't; among non-survivors, later elimination hole
                        = better rank; ties broken by lower total_net_score.
    """
    round               = models.ForeignKey(Round, on_delete=models.CASCADE, related_name='pink_ball_round_results')
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='pink_ball_round_result')
    eliminated_on_hole  = models.PositiveSmallIntegerField(
                            null=True, blank=True,
                            help_text="Hole where ball was lost. Null = survived all 18."
                        )
    total_net_score     = models.SmallIntegerField(null=True, blank=True)
    rank                = models.PositiveSmallIntegerField(null=True, blank=True)

    class Meta:
        unique_together = ('round', 'foursome')
        ordering        = ['rank']

    def __str__(self):
        if self.eliminated_on_hole:
            return f"Red Ball — Group {self.foursome.group_number} — Lost hole {self.eliminated_on_hole} — Rank {self.rank}"
        return f"Red Ball — Group {self.foursome.group_number} — SURVIVED — Rank {self.rank}"


# ---------------------------------------------------------------------------
# SCRAMBLE
# ---------------------------------------------------------------------------

class ScrambleHoleScore(models.Model):
    """
    One team score per hole in a scramble. The team is the Foursome.
    chosen_player records whose drive/shot was selected (optional, for stats).
    gross_score is the team's score for the hole.
    net_score = gross_score - team_handicap_strokes_on_hole (stored for performance).
    """
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='scramble_scores')
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    gross_score         = models.PositiveSmallIntegerField(null=True, blank=True)
    handicap_strokes    = models.PositiveSmallIntegerField(default=0)
    net_score           = models.PositiveSmallIntegerField(null=True, blank=True)
    chosen_player       = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='scramble_drives_used'
                        )

    class Meta:
        unique_together = ('foursome', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return f"Scramble — Group {self.foursome.group_number} — Hole {self.hole_number} — {self.gross_score}"


class ScrambleResult(models.Model):
    """
    Final scramble result for a Foursome in a Round.
    total_gross / total_net are summed from ScrambleHoleScore rows.
    drives_used is a JSON dict: {player_id: count} for validation against min_drives_per_player.
    rank is set when all groups complete.
    """
    round               = models.ForeignKey(Round, on_delete=models.CASCADE, related_name='scramble_results')
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='scramble_result')
    total_gross         = models.PositiveSmallIntegerField(null=True, blank=True)
    total_net           = models.PositiveSmallIntegerField(null=True, blank=True)
    drives_used         = models.JSONField(default=dict)
    rank                = models.PositiveSmallIntegerField(null=True, blank=True)

    class Meta:
        unique_together = ('round', 'foursome')

    def __str__(self):
        return f"Scramble result — Group {self.foursome.group_number} — {self.total_net} net"


# ---------------------------------------------------------------------------
# MATCH PLAY (within foursome, 2 × 9 holes, single elimination or points)
# ---------------------------------------------------------------------------

class MatchPlayBracket(models.Model):
    """
    The overall match play structure for one Foursome in one Round.
    For a 4-some: standard single elimination (2 semis + 1 final across 2×9).
    For a 3-some: 3 parallel 9-hole matches → points → top 2 play a 9-hole final.
    bracket_type: 'single_elim' or 'three_player_points'
    """
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='match_play_brackets')
    bracket_type        = models.CharField(
                            max_length=25,
                            choices=[('single_elim', 'Single Elimination'), ('three_player_points', '3-Player Points')]
                        )
    winner              = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='match_play_wins'
                        )
    status              = models.CharField(max_length=20, choices=MatchStatus.choices, default=MatchStatus.PENDING)

    def __str__(self):
        return f"Match Play — Group {self.foursome.group_number} — {self.bracket_type}"


class MatchPlayMatch(models.Model):
    """
    A single head-to-head 9-hole match within a bracket.
    round_number: 1=semi/opening, 2=final.
    start_hole: 1 or 10 (first or second 9).
    For 3-player-points brackets there is no round 2 here —
    the final is a separate MatchPlayMatch with round_number=2.
    holes_up tracks the running margin (positive = player1 leading).
    result: 'player1', 'player2', 'halved', or None if incomplete.
    """
    bracket             = models.ForeignKey(MatchPlayBracket, on_delete=models.CASCADE, related_name='matches')
    round_number        = models.PositiveSmallIntegerField()   # 1=opening, 2=final
    start_hole          = models.PositiveSmallIntegerField()   # 1 or 10
    player1             = models.ForeignKey(Player, on_delete=models.PROTECT, related_name='mp_matches_as_p1')
    player2             = models.ForeignKey(Player, on_delete=models.PROTECT, related_name='mp_matches_as_p2')
    status              = models.CharField(max_length=20, choices=MatchStatus.choices, default=MatchStatus.PENDING)
    result              = models.CharField(
                            max_length=10,
                            choices=[('player1','Player 1'),('player2','Player 2'),('halved','Halved')],
                            null=True, blank=True
                        )
    finished_on_hole    = models.PositiveSmallIntegerField(
                            null=True, blank=True,
                            help_text="Hole number the match was conceded/won (for early finish tracking)."
                        )

    def __str__(self):
        return f"R{self.round_number}: {self.player1.name} vs {self.player2.name} — {self.bracket}"


class MatchPlayHoleResult(models.Model):
    """
    Result of one hole within a MatchPlayMatch.
    winner is null on a halve.
    p1_net / p2_net stored for display.
    holes_up_after is the running margin after this hole
    (positive = player1 leading, negative = player2 leading).
    """
    match               = models.ForeignKey(MatchPlayMatch, on_delete=models.CASCADE, related_name='hole_results')
    hole_number         = models.PositiveSmallIntegerField()
    p1_net              = models.PositiveSmallIntegerField(null=True, blank=True)
    p2_net              = models.PositiveSmallIntegerField(null=True, blank=True)
    winner              = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='mp_holes_won'
                        )
    holes_up_after      = models.SmallIntegerField(default=0)

    class Meta:
        unique_together = ('match', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.match}"
