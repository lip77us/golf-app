from django.db import models
from django.utils import timezone

from core.models import GameType, RoundStatus, MatchStatus, Player, Tee, Course


# ---------------------------------------------------------------------------
# TOURNAMENT & ROUND
# ---------------------------------------------------------------------------

class Tournament(models.Model):
    """
    Groups multiple rounds into a single event.
    For Low Net Championship:
        - rounds_to_count=None means all rounds count
        - rounds_to_count=3 with total_rounds=5 means best 3 of 5
    For Match Play Championship the foursome winners from match_play rounds
    are collected and seeded into a separate bracket (see MatchPlayChampionship).
    """
    name                = models.CharField(max_length=150)
    start_date          = models.DateField()
    end_date            = models.DateField(null=True, blank=True)
    total_rounds        = models.PositiveSmallIntegerField(default=2)
    rounds_to_count     = models.PositiveSmallIntegerField(
                            null=True, blank=True,
                            help_text="None = all rounds count. Set to N for best-N-of-M."
                        )
    active_games        = models.JSONField(
                            default=list,
                            help_text="List of GameType values active for this tournament."
                        )
    created_at          = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name


class Round(models.Model):
    """
    A single day of golf. Can belong to a Tournament or stand alone.
    bet_unit is the dollar value of one unit for all games in this round.
    """
    tournament          = models.ForeignKey(
                            Tournament, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='rounds'
                        )
    round_number        = models.PositiveSmallIntegerField(default=1)
    date                = models.DateField(default=timezone.now)
    course              = models.ForeignKey(Course, on_delete=models.PROTECT, related_name='rounds')
    status              = models.CharField(max_length=20, choices=RoundStatus.choices, default=RoundStatus.PENDING)
    active_games        = models.JSONField(
                            default=list,
                            help_text="List of GameType values active for this round."
                        )
    bet_unit            = models.DecimalField(max_digits=6, decimal_places=2, default=1.00)
    scramble_config     = models.JSONField(
                            null=True, blank=True,
                            help_text=(
                                "Config for scramble if active. Example: "
                                "{'min_drives_per_player': 2, 'handicap_pct': 0.20}"
                            )
                        )
    notes               = models.TextField(blank=True)
    created_at          = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Round {self.round_number} — {self.date} @ {self.course.name}"


# ---------------------------------------------------------------------------
# FOURSOME & MEMBERSHIP
# ---------------------------------------------------------------------------

class Foursome(models.Model):
    """
    One group of 2–4 players (padded to 4 with a phantom if 3-some).
    pink_ball_order stores a JSON list of player PKs in hole order:
        [player_id_hole1, player_id_hole2, ..., player_id_hole18]
    group_number is 1-based (Group 1, Group 2, ...).
    """
    round               = models.ForeignKey(Round, on_delete=models.CASCADE, related_name='foursomes')
    group_number        = models.PositiveSmallIntegerField()
    pink_ball_order     = models.JSONField(
                            default=list,
                            help_text="Ordered list of player PKs for pink ball rotation."
                        )
    has_phantom         = models.BooleanField(default=False)

    class Meta:
        unique_together = ('round', 'group_number')
        ordering = ['group_number']

    def real_players(self):
        return self.memberships.filter(player__is_phantom=False).select_related('player')

    def all_players(self):
        return self.memberships.all().select_related('player')

    def player_count(self):
        return self.memberships.filter(player__is_phantom=False).count()

    def __str__(self):
        return f"Group {self.group_number} — {self.round}"


class FoursomeMembership(models.Model):
    """
    Links a Player to a Foursome with their pre-calculated course handicap
    and any phantom flag for quick access.
    course_handicap is stored here (not recalculated per query) since slope/rating
    may change if the tee set is edited after the round starts.
    """
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='memberships')
    player              = models.ForeignKey(Player, on_delete=models.PROTECT, related_name='memberships')
    tee                 = models.ForeignKey(Tee, on_delete=models.PROTECT, related_name='memberships', null=True)
    course_handicap     = models.SmallIntegerField(
                            help_text="Pre-calculated and stored at round setup."
                        )
    playing_handicap    = models.SmallIntegerField(
                            help_text="course_handicap adjusted by any local allowance (e.g. 90%)."
                        )

    class Meta:
        unique_together = ('foursome', 'player')

    def handicap_strokes_on_hole(self, stroke_index):
        """
        Returns the number of handicap strokes this player receives on a hole
        given the hole's stroke_index (1=hardest, 18=easiest).
        A playing handicap of 20 gives 1 stroke on holes SI 1–18 and
        2 strokes on holes SI 1–2.
        """
        full_strokes = self.playing_handicap // 18
        remainder = self.playing_handicap % 18
        extra = 1 if stroke_index <= remainder else 0
        return full_strokes + extra

    def __str__(self):
        return f"{self.player.name} in {self.foursome}"


# ---------------------------------------------------------------------------
# MATCH PLAY CHAMPIONSHIP (foursome winners, day 2 bracket)
# ---------------------------------------------------------------------------

class MatchPlayChampionship(models.Model):
    """
    Tournament-level bracket. Seeds are the foursome winners from
    all match play rounds in the tournament.
    Up to 4 seeds (one per foursome × up to 4 foursomes).
    The bracket is a simple single-elimination mini-tournament played
    across the round(s) on day 2.
    """
    tournament          = models.OneToOneField(Tournament, on_delete=models.CASCADE, related_name='mp_championship')
    seeds               = models.ManyToManyField(Player, through='ChampionshipSeed', related_name='championship_seeds')
    champion            = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='championships_won'
                        )
    status              = models.CharField(max_length=20, choices=MatchStatus.choices, default=MatchStatus.PENDING)

    def __str__(self):
        return f"Match Play Championship — {self.tournament}"


class ChampionshipSeed(models.Model):
    """Through model for MatchPlayChampionship seeds, storing seed number."""
    championship        = models.ForeignKey(MatchPlayChampionship, on_delete=models.CASCADE)
    player              = models.ForeignKey(Player, on_delete=models.PROTECT)
    seed_number         = models.PositiveSmallIntegerField()
    source_foursome     = models.ForeignKey(
                            Foursome, on_delete=models.SET_NULL, null=True,
                            help_text="The foursome this player won to earn their seed."
                        )

    class Meta:
        unique_together = ('championship', 'seed_number')

    def __str__(self):
        return f"Seed {self.seed_number}: {self.player.name}"
