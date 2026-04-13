from django.db import models
from django.core.validators import MinValueValidator, MaxValueValidator

from core.models import Player
from tournament.models import Round, Foursome, Tournament


# ---------------------------------------------------------------------------
# HOLE SCORES — single source of truth
# ---------------------------------------------------------------------------

class HoleScore(models.Model):
    """
    One row per player per hole per foursome.
    net_score is stored (not computed) for query performance.
    handicap_strokes_received is denormalised from FoursomeMembership
    for the same reason.
    Phantom players get gross_score = hole par + 1 assigned at round setup.
    """
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='hole_scores')
    player              = models.ForeignKey(Player, on_delete=models.PROTECT, related_name='hole_scores')
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    gross_score         = models.PositiveSmallIntegerField(null=True, blank=True)
    handicap_strokes    = models.PositiveSmallIntegerField(default=0)
    net_score           = models.PositiveSmallIntegerField(null=True, blank=True)
    # Stableford points derived from net score vs par
    stableford_points   = models.SmallIntegerField(null=True, blank=True)

    class Meta:
        unique_together = ('foursome', 'player', 'hole_number')
        ordering = ['hole_number']

    def save(self, *args, **kwargs):
        """Auto-calculate net_score and stableford_points before saving."""
        if self.gross_score is not None:
            self.net_score = self.gross_score - self.handicap_strokes
            tee = self.foursome.round.course
            hole_par = tee.hole(self.hole_number)['par']
            diff = self.net_score - hole_par
            self.stableford_points = max(0, 2 - diff)
        super().save(*args, **kwargs)

    def __str__(self):
        return f"{self.player.name} — Hole {self.hole_number} — {self.gross_score} ({self.net_score} net)"


# ---------------------------------------------------------------------------
# STABLEFORD (individual, net points per hole)
# ---------------------------------------------------------------------------

class StablefordResult(models.Model):
    """
    Aggregated Stableford result for a Player in a Round.
    Points are already stored per-hole in HoleScore.stableford_points.
    This model caches the total for leaderboard queries.
    Points scale:
        Albatross (+3 or better vs par net) = 5
        Eagle     (+2 net)                  = 4
        Birdie    (+1 net)                  = 3
        Par       (0 net)                   = 2
        Bogey     (-1 net)                  = 1
        Double+   (-2 or worse net)         = 0
    """
    round               = models.ForeignKey(Round, on_delete=models.CASCADE, related_name='stableford_results')
    player              = models.ForeignKey(Player, on_delete=models.PROTECT, related_name='stableford_results')
    total_points        = models.SmallIntegerField(default=0)
    rank                = models.PositiveSmallIntegerField(null=True, blank=True)

    class Meta:
        unique_together = ('round', 'player')
        ordering = ['-total_points']

    def __str__(self):
        return f"Stableford — {self.player.name} — {self.total_points} pts — {self.round}"


# ---------------------------------------------------------------------------
# SKINS (within foursome, carryover)
# ---------------------------------------------------------------------------

class SkinsResult(models.Model):
    """
    One row per hole per foursome. winner is null if the hole is tied (carryover).
    skins_value includes any carried-over skins from previous tied holes.
    """
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='skins_results')
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    winner              = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='skins_won'
                        )
    skins_value         = models.PositiveSmallIntegerField(default=1)
    is_carryover        = models.BooleanField(default=False)

    class Meta:
        unique_together = ('foursome', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return f"Skins — Hole {self.hole_number} — {self.winner or 'Tied'} ({self.skins_value} skin(s))"

# ---------------------------------------------------------------------------
# SKINS (within foursome, no carryover)
# ---------------------------------------------------------------------------

class SkinsResultNoCarryover(models.Model):
    """
    One row per hole per foursome. winner is null if the hole is tied.
    skins_value do not any carried-over skins from previous tied holes.
    """
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='skins_results_no_carryover')
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    winner              = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='skins_results_no_carryover'
                        )
    skins_value         = models.PositiveSmallIntegerField(default=1)
    is_carryover        = models.BooleanField(default=False)

    class Meta:
        unique_together = ('foursome', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return f"Skins — Hole {self.hole_number} — {self.winner or 'Tied'} ({self.skins_value} skin(s))"


# ---------------------------------------------------------------------------
# LOW NET CHAMPIONSHIP (tournament-level, individual)
# ---------------------------------------------------------------------------

class LowNetResult(models.Model):
    """
    Aggregated low net result for a Player across a Tournament.
    round_scores is a JSON list of net totals per round:
        [{"round_id": 1, "net_total": 71}, {"round_id": 2, "net_total": 69}]
    counted_scores is the subset that counts toward the championship
    (all of them, or best N depending on Tournament.rounds_to_count).
    final_net is the sum of counted_scores.
    """
    tournament          = models.ForeignKey(Tournament, on_delete=models.CASCADE, related_name='low_net_results')
    player              = models.ForeignKey(Player, on_delete=models.PROTECT, related_name='low_net_results')
    round_scores        = models.JSONField(default=list)
    counted_scores      = models.JSONField(default=list)
    final_net           = models.SmallIntegerField(null=True, blank=True)
    rank                = models.PositiveSmallIntegerField(null=True, blank=True)

    class Meta:
        unique_together = ('tournament', 'player')
        ordering = ['final_net']

    def calculate_final_net(self):
        """
        Recalculate final_net and counted_scores from round_scores.
        Call this whenever a round score is added or updated.
        """
        scores = sorted([r['net_total'] for r in self.round_scores])
        n = self.tournament.rounds_to_count
        self.counted_scores = scores[:n] if n else scores
        self.final_net = sum(self.counted_scores)

    def __str__(self):
        return f"Low Net — {self.player.name} — {self.final_net} — {self.tournament}"
