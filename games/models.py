from django.db import models
from django.core.validators import MinValueValidator, MaxValueValidator

from core.models import MatchStatus, TeamSelectMethod, Player
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
# NASSAU (9-9-18 fixed-team best ball match play with auto-press)
# ---------------------------------------------------------------------------

NASSAU_RESULT_CHOICES = [
    ('team1',  'Team 1'),
    ('team2',  'Team 2'),
    ('halved', 'Halved'),
]


class NassauGame(models.Model):
    """
    The Nassau game for one Foursome. Teams are fixed for all 18 holes.

    Three simultaneous bets:
      - Front 9  (holes 1–9)
      - Back 9   (holes 10–18)
      - Overall  (all 18)

    Auto-press rule: when a team is 2 down at any point within a 9,
    the trailing team gets an automatic press. The press covers only
    the remaining holes in that 9 (tracked in NassauPress).

    front9_result / back9_result / overall_result: set when each
    concludes ('team1', 'team2', or 'halved').
    """
    foursome            = models.OneToOneField(Foursome, on_delete=models.CASCADE, related_name='nassau_game')
    press_pct           = models.DecimalField(
                            max_digits=4, decimal_places=2, default='0.50',
                            help_text="Press bet as a fraction of the round bet_unit (e.g. 0.50 = half)."
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

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.game}"


class NassauPress(models.Model):
    """
    An auto-press bet within a NassauGame.

    Triggered when a team goes 2 down within a 9. The press covers
    the remaining holes in that 9 only (start_hole to end-of-nine).

    nine:             'front' (holes 1-9) or 'back' (holes 10-18)
    triggered_on_hole: the hole where the press was triggered
    start_hole:       first hole of the press (= triggered_on_hole + 1)
    end_hole:         last hole of that 9 (9 or 18)
    result:           set when the press concludes
    holes_up:         final margin of the press (positive = team1 won)
    """
    game                = models.ForeignKey(NassauGame, on_delete=models.CASCADE, related_name='presses')
    nine                = models.CharField(
                            max_length=5,
                            choices=[('front', 'Front 9'), ('back', 'Back 9')]
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
        return f"Press hole {self.triggered_on_hole} ({self.nine}) — {self.game}"


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
    """
    round               = models.OneToOneField(Round, on_delete=models.CASCADE, related_name='irish_rumble_config')
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
