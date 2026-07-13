from django.db import models
from django.core.validators import MinValueValidator, MaxValueValidator

from core.models import MatchStatus, TeamSelectMethod, HandicapMode, Player, GameType
from tournament.models import Round, Foursome


# ---------------------------------------------------------------------------
# SIX'S (3 × 6-hole rotating-team best ball match play within foursome)
# ---------------------------------------------------------------------------

class SixesSegment(models.Model):
    """
    One 6-hole block of the Sixes game. Standard play has 3 segments
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

    Scoring format (see `scoring_format` below):
      - classic:  1 point per hole.  Best ball: lowest net per team wins
                  the hole.  Match-play closeout (lead > holes remaining).
                  Extra matches collect leftover holes after early finishes.
      - high_low: 2 points per hole.  1 pt for best-net vs best-net (low),
                  1 pt for worst-net vs worst-net (high).  Closeout when
                  point lead exceeds 2 * holes remaining in the segment.
                  No extra matches — all 18 holes are played, post-closeout
                  scores are entered but don't add to that segment's points.
                  Overall round winner = count of segments won.
    """
    SCORING_FORMAT_CHOICES = (
        ('classic',  'Classic (best ball, 1 pt/hole)'),
        ('high_low', 'High-Low (best+worst, 2 pts/hole)'),
    )
    # Handicap allocation modes — orthogonal to handicap_mode below.
    # 'per_segment' is the historical Sixes behavior for STROKES_OFF mode
    # (player's SO is split across the 3 segments: floor(SO/3) plus 1 for
    # the first SO%3 matches).  'full_round' allocates all strokes on the
    # round-wide stroke index (a player with N strokes gets one on every
    # hole where SI <= N) — same as a normal NET round, just applied to
    # SO mode.  Has no effect when handicap_mode is 'net' or 'gross'
    # (those already allocate round-wide / not at all, respectively).
    HCAP_ALLOCATION_CHOICES = (
        ('per_segment', 'Spread across 3 segments'),
        ('full_round',  'Round-wide (strokes on hardest holes)'),
    )

    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='sixes_segments')
    segment_number      = models.PositiveSmallIntegerField()
    start_hole          = models.PositiveSmallIntegerField()
    end_hole            = models.PositiveSmallIntegerField()
    status              = models.CharField(max_length=20, choices=MatchStatus.choices, default=MatchStatus.PENDING)
    is_extra            = models.BooleanField(
                            default=False,
                            help_text="True for the 4th match created from leftover holes after an early finish."
                        )
    # Mid-round withdrawal: when a player can't continue, the TD may choose to
    # VOID the segment that contains/follows the withdrawal (vs. having the
    # remaining partner play solo). A voided segment awards 0 points and is
    # excluded from totals, money, and closeout. See docs/mid-round-withdrawal.md.
    is_void             = models.BooleanField(
                            default=False,
                            help_text="True if voided due to a mid-round withdrawal; "
                                      "scores 0 points and is excluded from totals.",
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
    scoring_format      = models.CharField(
                            max_length=20,
                            choices=SCORING_FORMAT_CHOICES,
                            default='classic',
                            help_text=(
                                "Scoring rules.  'classic' = best-ball 1 pt/hole "
                                "with extras; 'high_low' = low+high 2 pts/hole, "
                                "3 segments only, strict point-based closeout."
                            ),
                        )
    handicap_allocation = models.CharField(
                            max_length=20,
                            choices=HCAP_ALLOCATION_CHOICES,
                            default='per_segment',
                            help_text=(
                                "Only meaningful for handicap_mode='strokes_off'. "
                                "'per_segment' splits SO across the 3 matches "
                                "(legacy default); 'full_round' allocates strokes "
                                "by round-wide stroke index instead."
                            ),
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
    Per-hole result for one hole within a SixesSegment.

    For classic format, this stores best-ball results (1 pt/hole).
    For high_low format, it also stores worst-net values + per-team points.

    winning_team is null on a halve (1-1 in high_low or tied in classic).
    holes_up_after: running point differential after this hole
        (positive = team1 leading, negative = team2 leading).  For classic
        this matches "holes up"; for high_low it's the points-up margin.
    team1_points / team2_points: points awarded this hole.
        classic:  exactly one of (1,0) / (0,0 halve) / (0,1).
        high_low: any combination of (0-2, 0-2) summing to 0 or 2.
    """
    segment             = models.ForeignKey(SixesSegment, on_delete=models.CASCADE, related_name='hole_results')
    hole_number         = models.PositiveSmallIntegerField()
    team1_best_net      = models.SmallIntegerField(null=True, blank=True)
    team2_best_net      = models.SmallIntegerField(null=True, blank=True)
    team1_worst_net     = models.SmallIntegerField(null=True, blank=True,
                            help_text="High-Low only: the higher of team 1's two nets.")
    team2_worst_net     = models.SmallIntegerField(null=True, blank=True,
                            help_text="High-Low only: the higher of team 2's two nets.")
    team1_points        = models.PositiveSmallIntegerField(
                            default=0,
                            help_text="Points awarded to team 1 on this hole (0/1 classic, 0-2 high_low)."
                        )
    team2_points        = models.PositiveSmallIntegerField(
                            default=0,
                            help_text="Points awarded to team 2 on this hole (0/1 classic, 0-2 high_low)."
                        )
    winning_team        = models.ForeignKey(
                            SixesTeam, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='holes_won'
                        )
    holes_up_after      = models.SmallIntegerField(
                            default=0,
                            help_text="Running point margin after this hole: +ve = team1 leading."
                        )
    counts_for_segment  = models.BooleanField(
                            default=True,
                            help_text=(
                                "High-Low only: False for holes played after "
                                "the segment closed out — the score is "
                                "recorded but doesn't add to segment points."
                            ),
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
    loss_cap            = models.DecimalField(
                            max_digits=8, decimal_places=2,
                            null=True, blank=True,
                            help_text=(
                                "Optional per-side loss cap (one table-wide value "
                                "applied per player). Null = uncapped; the "
                                "theoretical max 5-3-1 loss is 36 × bet_unit "
                                "(2 pts/hole below the mean × 18), so a null cap "
                                "and 36×bet_unit are equivalent. When set lower, "
                                "losers clip at the cap and winners are reduced "
                                "pro-rata — see services.wager.settle()."
                            ),
                        )
    # Money model (2-axis, shared with Skins/Spots/Stableford via
    # services.wager). ``bet_unit`` IS the value of one point (the rate) —
    # no separate rate field.
    #   pool                    — everyone antes bet_unit; the pot splits by
    #                             share of points (PROPORTIONAL). Entry is the cap.
    #   per_point + 'average'   — the CLASSIC 5-3-1: (points − mean) × bet_unit
    #                             (VS_AVERAGE). This is the default.
    #   per_point + 'all'       — pay everyone above you (PAY_ABOVE).
    #   per_point + 'first'     — only the leader collects (PAY_WINNER).
    PAYOUT_STYLES   = [('pool', 'Pool'), ('per_point', 'Per point')]
    payout_style    = models.CharField(max_length=12, choices=PAYOUT_STYLES,
                                       default='per_point')
    PER_POINT_MODES = [
        ('average', 'Settle vs the field average'),
        ('all',     'Pay everyone above you'),
        ('first',   'Pay the leader'),
    ]
    per_point_mode  = models.CharField(max_length=8, choices=PER_POINT_MODES,
                                       default='average')
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

    # ── Payout mode (2-axis, shared with Stableford; maps to services.wager) ──
    # 'pool' keeps the classic Skins economics (each player antes Round.bet_unit;
    # the pot splits by share of total skins — WD-aware, see services.skins).
    # 'per_point' settles on total skins via services.wager.settle at the chosen
    # per_point_mode/rate (pay leader / pay above / vs average).
    PAYOUT_STYLES  = [('pool', 'Pool'), ('per_point', 'Per skin')]
    payout_style   = models.CharField(max_length=12, choices=PAYOUT_STYLES,
                                      default='pool')
    PER_POINT_MODES = [
        ('average', 'Settle vs the field average'),
        ('all',     'Pay everyone above you'),
        ('first',   'Pay the leader'),
    ]
    per_point_mode = models.CharField(max_length=8, choices=PER_POINT_MODES,
                                      default='first')
    per_point_rate = models.DecimalField(
                        max_digits=6, decimal_places=2, default=0.00,
                        help_text="$ per skin of margin (per_point style).")
    loss_cap       = models.DecimalField(
                        max_digits=8, decimal_places=2, null=True, blank=True,
                        help_text="Optional per-player loss cap (per_point "
                                  "style); null = uncapped.")
    # Player IDs actually IN this Skins game (a SUBSET side game — e.g. 2 of a
    # 4-some). Empty = all real players in the foursome. Flows through the pool,
    # per-hole winner, carryover, junk, and WD segments. docs/parallel-games.md.
    participant_player_ids = models.JSONField(default=list)
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
# SPOTS (capture add-on: user-defined per-hole achievements, separate pot)
# ---------------------------------------------------------------------------

class SpotsGame(models.Model):
    """
    Spots for one Foursome (2–4 real players).  A "spot" is a user-defined
    per-hole achievement the app can't detect (one-putt, sandy, barky, …); the
    scorer tallies them by hand per player per hole, like junk.  Always a
    SEPARATE payout — never folded into the main game.

    Settlement (2-axis, shared with the other points games; maps to
    services.wager). ``bet_unit`` IS the per-spot rate (no separate field):
      - pool: everyone antes bet_unit; the pot splits by share of spots.
      - per_point + 'all'  = "pay around" (each spot pays the achiever bet_unit
        from every other active player — per-hole, withdrawal-aware).
      - per_point + 'first' = only the leader collects the deficit.
      - per_point + 'average' = settle vs the field average.
    """
    foursome     = models.OneToOneField(
                    Foursome, on_delete=models.CASCADE,
                    related_name='spots_game',
                )
    status       = models.CharField(
                    max_length=20, choices=MatchStatus.choices,
                    default=MatchStatus.PENDING,
                )
    bet_unit     = models.DecimalField(
                    max_digits=6, decimal_places=2, default=1,
                    help_text="Value of one spot.",
                )
    # 2-axis payout (maps to services.wager). Default preserves the historical
    # "pay around" behavior (per_point + 'all').
    payout_style   = models.CharField(
                    max_length=12,
                    choices=[('pool', 'Pool'), ('per_point', 'Per spot')],
                    default='per_point',
                )
    per_point_mode = models.CharField(
                    max_length=8,
                    choices=[('average', 'Settle vs the field average'),
                             ('all',     'Pay everyone above you'),
                             ('first',   'Pay the leader')],
                    default='all',
                )
    loss_cap       = models.DecimalField(
                    max_digits=8, decimal_places=2, null=True, blank=True,
                    help_text="Optional per-player loss cap (per_point style); "
                              "null = uncapped.")
    created_at   = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Spots — Group {self.foursome.group_number}"


class SpotsPlayerHoleResult(models.Model):
    """
    Manually entered spot counts per player per hole.  Only rows with count > 0
    need persisting; the settlement reads these directly (no detection).
    """
    game        = models.ForeignKey(
                    SpotsGame, on_delete=models.CASCADE,
                    related_name='hole_results',
                )
    player      = models.ForeignKey(
                    Player, on_delete=models.CASCADE,
                    related_name='spots_results',
                )
    hole_number = models.PositiveSmallIntegerField(
                    validators=[MinValueValidator(1), MaxValueValidator(18)]
                )
    count       = models.SmallIntegerField(
                    default=0,
                    help_text="Spots earned by this player on this hole "
                              "(negative = a reverse spot / penalty).",
                )

    class Meta:
        unique_together = ('game', 'player', 'hole_number')
        ordering        = ['hole_number', 'player_id']

    def __str__(self):
        return (f"Spots ×{self.count} — {self.player.name} "
                f"hole {self.hole_number} ({self.game})")


# ---------------------------------------------------------------------------
# WOLF (3- or 4-player rotating-wolf game, casual-round only)
# ---------------------------------------------------------------------------

class WolfGame(models.Model):
    """
    The Wolf game for one Foursome.  Designed for 3 or 4 real players
    (phantoms excluded).  On every hole one player is the Wolf — derived
    from ``wolf_order`` (a seat rotation the group sets, like Pink Ball's
    carrier order): wolf for hole H = wolf_order[(H-1) % n].  In a
    4-player game, holes 17–18 instead hand the Wolf to whoever is in
    last place (fewest points so far) when ``last_place_wolf_1718`` is on.

    The Wolf either takes a partner (4-player only → 2v2), goes Lone Wolf
    (1-vs-rest), or Blind Wolf (1-vs-rest, declared pre-tee).  Best ball
    per side decides the hole.

    Scoring is zero-based: each scored hole has a pot that the winning
    side splits (+) and the losing side splits (−), so the table always
    nets to zero.  Pot sizing:
        * Lone hole  → pot = lone_wolf_points  (default 3)
        * Blind hole → pot = blind_wolf_points (default 6)
        * Partner    → each winner gets team_win_points (default 1), or
                       2× that when the NON-wolf side wins and
                       non_wolf_bonus is on ("a clean win against the
                       team that had the pick advantage").
    Options:
        * wolf_loses_ties — a tied hole is awarded to the non-wolf side
          instead of being a push (the Wolf must win outright).
        * non_wolf_bonus  — non-wolf side's clean win pays double (above).

    Settlement: money for a player = their total points × Round.bet_unit.
    Because every hole nets to zero, the players' money sums to zero too.
    """
    foursome              = models.OneToOneField(
                                Foursome, on_delete=models.CASCADE,
                                related_name='wolf_game',
                            )
    status                = models.CharField(
                                max_length=20,
                                choices=MatchStatus.choices,
                                default=MatchStatus.PENDING,
                            )
    handicap_mode         = models.CharField(
                                max_length=20,
                                choices=HandicapMode.choices,
                                default=HandicapMode.NET,
                                help_text="How per-hole scores are adjusted for ranking.",
                            )
    net_percent           = models.PositiveSmallIntegerField(
                                default=100,
                                validators=[MinValueValidator(0), MaxValueValidator(200)],
                                help_text="Percentage of playing handicap applied when "
                                          "handicap_mode='net'.",
                            )
    # Rotation order — JSON list of real player ids.  wolf for hole H =
    # wolf_order[(H-1) % len].  Empty falls back to membership order.
    wolf_order            = models.JSONField(
                                default=list, blank=True,
                                help_text="Ordered player ids; the Wolf rotates through "
                                          "this list one hole at a time.",
                            )
    lone_wolf_points      = models.PositiveSmallIntegerField(
                                default=3,
                                help_text="Pot for a Lone Wolf hole (Wolf goes alone "
                                          "after watching the drives).",
                            )
    blind_wolf_points     = models.PositiveSmallIntegerField(
                                default=6,
                                help_text="Pot for a Blind Wolf hole (Wolf declares "
                                          "alone before any tee shots).",
                            )
    team_win_points       = models.PositiveSmallIntegerField(
                                default=1,
                                help_text="Points each winner nets on a partner (2v2) hole.",
                            )
    wolf_loses_ties       = models.BooleanField(
                                default=False,
                                help_text="If True a tied hole is awarded to the non-wolf "
                                          "side instead of being a push.",
                            )
    non_wolf_bonus        = models.BooleanField(
                                default=False,
                                help_text="If True a clean win by the non-wolf side on a "
                                          "partner hole pays double.",
                            )
    last_place_wolf_1718  = models.BooleanField(
                                default=True,
                                help_text="4-player only: on holes 17 & 18 the player in "
                                          "last place becomes the Wolf (catch-up rule).",
                            )
    require_lone_or_blind = models.BooleanField(
                                default=False,
                                help_text="4-player only: every player must go Lone or "
                                          "Blind at least once in holes 1-16.  Once a "
                                          "player has been Wolf 3 times all as partner, "
                                          "their next (last) Wolf turn locks out the "
                                          "partner option.",
                            )
    # Optional per-player loss cap. Null = uncapped. Wolf points already net to
    # zero per hole, so money is points × bet_unit; a cap clips losers and
    # rescales winners pro-rata via services.wager.settle().
    loss_cap              = models.DecimalField(
                                max_digits=8, decimal_places=2,
                                null=True, blank=True,
                                help_text="Optional per-player loss cap; "
                                          "null = uncapped.",
                            )
    created_at            = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Wolf — Group {self.foursome.group_number}"


class WolfHoleDecision(models.Model):
    """
    The Wolf's choice on a single hole.  One row per hole the Wolf has
    acted on; absent rows mean "no decision yet" (the hole is not scored
    even if all gross scores are in).

    decision:
        * 'pending' — placeholder; treated as no decision.
        * 'partner' — Wolf + ``partner`` vs the rest (4-player only).
        * 'lone'    — Wolf alone vs the rest (declared after drives).
        * 'blind'   — Wolf alone vs the rest (declared before drives).
    partner: the chosen teammate; only meaningful for decision='partner'.
    The Wolf's own identity is NOT stored here — it is derived from the
    game's rotation so it always stays consistent if the order changes.
    """
    PENDING = 'pending'
    PARTNER = 'partner'
    LONE    = 'lone'
    BLIND   = 'blind'
    DECISION_CHOICES = [
        (PENDING, 'Pending'),
        (PARTNER, 'Partner'),
        (LONE,    'Lone Wolf'),
        (BLIND,   'Blind Wolf'),
    ]

    game        = models.ForeignKey(
                    WolfGame, on_delete=models.CASCADE,
                    related_name='decisions',
                )
    hole_number = models.PositiveSmallIntegerField(
                    validators=[MinValueValidator(1), MaxValueValidator(18)]
                )
    decision    = models.CharField(
                    max_length=10, choices=DECISION_CHOICES, default=PENDING,
                )
    partner     = models.ForeignKey(
                    Player, on_delete=models.SET_NULL,
                    null=True, blank=True,
                    related_name='wolf_partner_holes',
                )

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.decision} ({self.game})"


class WolfPlayerHoleResult(models.Model):
    """
    One calculated row per (game, player, hole) once that hole has both a
    Wolf decision and a gross score for every real player.  Records the
    net score used for ranking, the player's role on the hole, and the
    points awarded (Decimal — uneven sides in a 3-player Lone hole split
    the pot into halves, e.g. ±1.5).
    """
    ROLE_WOLF     = 'wolf'
    ROLE_PARTNER  = 'partner'
    ROLE_OPPONENT = 'opponent'
    ROLE_CHOICES  = [
        (ROLE_WOLF,     'Wolf'),
        (ROLE_PARTNER,  'Partner'),
        (ROLE_OPPONENT, 'Opponent'),
    ]

    game        = models.ForeignKey(
                    WolfGame, on_delete=models.CASCADE,
                    related_name='hole_results',
                )
    player      = models.ForeignKey(
                    Player, on_delete=models.CASCADE,
                    related_name='wolf_hole_results',
                )
    hole_number = models.PositiveSmallIntegerField(
                    validators=[MinValueValidator(1), MaxValueValidator(18)]
                )
    net_score   = models.SmallIntegerField(
                    help_text="The score used for ranking (net/gross/SO-adjusted).",
                )
    role        = models.CharField(
                    max_length=10, choices=ROLE_CHOICES, default=ROLE_OPPONENT,
                )
    points      = models.DecimalField(
                    max_digits=5, decimal_places=2,
                    help_text="Per-hole points; zero-based so each hole sums to 0.",
                )

    class Meta:
        unique_together = ('game', 'player', 'hole_number')
        ordering        = ['hole_number', '-points']

    def __str__(self):
        return (f"Hole {self.hole_number} — {self.player.name} — "
                f"{self.points} ({self.role})")


# ---------------------------------------------------------------------------
# RABBIT (3-player "catch the rabbit" game, casual-round only)
# ---------------------------------------------------------------------------

class RabbitGame(models.Model):
    """
    The Rabbit game for one Foursome (exactly 3 real players; phantoms
    ignored).  The first player to win a hole outright catches the rabbit
    and runs ahead; they hold it until an opponent beats them on a hole.

    accumulate:
        * True  — the holder builds a lead: +1 for each hole they win as
          rabbit, −1 for each hole they lose; they only lose the rabbit
          when the lead drops to 0 (then it's up for grabs).
        * False — "stop after one": the holder loses the rabbit on the
          first hole they're beaten (lead is effectively capped at 1).

    num_segments: 1 (one 18-hole match), 2 (two 9-hole matches) or 3
        (three 6-hole matches).  The rabbit resets at the start of each
        segment; whoever holds it when a segment ends wins that segment's
        share of the pot (whole / half / third).  A segment that ends with
        the rabbit loose is a push.

    Settlement: pot = Round.bet_unit; each segment is worth
        pot / num_segments, paid by the two non-holders equally (zero-sum).
    """
    foursome      = models.OneToOneField(
                        Foursome, on_delete=models.CASCADE,
                        related_name='rabbit_game',
                    )
    status        = models.CharField(
                        max_length=20,
                        choices=MatchStatus.choices,
                        default=MatchStatus.PENDING,
                    )
    handicap_mode = models.CharField(
                        max_length=20,
                        choices=HandicapMode.choices,
                        default=HandicapMode.NET,
                        help_text="How per-hole scores are adjusted for ranking.",
                    )
    net_percent   = models.PositiveSmallIntegerField(
                        default=100,
                        validators=[MinValueValidator(0), MaxValueValidator(200)],
                        help_text="Percentage of playing handicap applied when "
                                  "handicap_mode='net'.",
                    )
    accumulate    = models.BooleanField(
                        default=True,
                        help_text="True: rabbit builds a lead (+1 win / −1 loss), "
                                  "lost only when the lead hits 0.  False: lost on "
                                  "the first hole the rabbit is beaten.",
                    )
    num_segments  = models.PositiveSmallIntegerField(
                        default=1,
                        validators=[MinValueValidator(1), MaxValueValidator(3)],
                        help_text="1 = one 18-hole match, 2 = two 9-hole matches, "
                                  "3 = three 6-hole matches.",
                    )
    created_at    = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Rabbit — Group {self.foursome.group_number}"


class RabbitHoleResult(models.Model):
    """
    Calculated per-hole state for a RabbitGame.  One row per hole that has
    a gross score for all three real players.

    winner:  the outright hole winner (strictly lowest score), or null on a
             tie for low.
    holder:  who holds the rabbit *after* this hole, or null if it's loose.
    lead:    the holder's lead after this hole (0 when loose).
    event:   what happened — 'grab' (caught a loose rabbit), 'extend'
             (rabbit won, lead grew), 'held' (rabbit held, no lead change),
             'beaten' (rabbit lost a hole, lead dropped but still held),
             'freed' (rabbit's lead hit 0 → loose), 'tie' / 'none'
             (no change).
    """
    GRAB   = 'grab'
    EXTEND = 'extend'
    HELD   = 'held'
    BEATEN = 'beaten'
    FREED  = 'freed'
    TIE    = 'tie'
    NONE   = 'none'
    EVENT_CHOICES = [
        (GRAB, 'Grabbed'), (EXTEND, 'Extended'), (HELD, 'Held'),
        (BEATEN, 'Beaten'), (FREED, 'Freed'), (TIE, 'Tie'), (NONE, 'None'),
    ]

    game        = models.ForeignKey(
                    RabbitGame, on_delete=models.CASCADE,
                    related_name='hole_results',
                )
    hole_number = models.PositiveSmallIntegerField(
                    validators=[MinValueValidator(1), MaxValueValidator(18)]
                )
    segment     = models.PositiveSmallIntegerField(default=1)
    winner      = models.ForeignKey(
                    Player, on_delete=models.SET_NULL, null=True, blank=True,
                    related_name='rabbit_holes_won',
                )
    holder      = models.ForeignKey(
                    Player, on_delete=models.SET_NULL, null=True, blank=True,
                    related_name='rabbit_holes_held',
                )
    lead        = models.PositiveSmallIntegerField(default=0)
    event       = models.CharField(
                    max_length=10, choices=EVENT_CHOICES, default=NONE,
                )

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        h = self.holder.short_name if self.holder else 'loose'
        return f"Hole {self.hole_number} — rabbit: {h} (+{self.lead})"


# ---------------------------------------------------------------------------
# MULTI-FOURSOME SKINS (Round-scoped, pooled across every participating group)
# ---------------------------------------------------------------------------

class MultiSkinsGame(models.Model):
    """
    Round-level skins pool that crosses foursomes.  Each player opts in
    individually; the roster is explicit (not the union of every
    foursome's roster).  Lowest score on a hole wins 1 skin; any tie
    kills the skin.  No carryover, no junk — intentionally simple.

    Settlement: pool = bet_unit × participants; payout is proportional
    to skins won.  Players with zero skins receive nothing.
    """
    round           = models.OneToOneField(
                        Round, on_delete=models.CASCADE,
                        related_name='multi_skins_game',
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
    bet_unit        = models.DecimalField(
                        max_digits=6, decimal_places=2, default=10.00,
                        help_text="Dollar entry fee per participating player.",
                    )
    participants    = models.ManyToManyField(
                        Player,
                        related_name='multi_skins_games',
                        help_text="Players who paid into this pool. A player "
                                  "may belong to any foursome in this round.",
                    )
    created_at      = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Multi-Skins — Round {self.round_id}"


class MultiSkinsHoleResult(models.Model):
    """
    Calculated per-hole outcome for a MultiSkinsGame.  One row per hole
    for which every participant has submitted a gross score.

    winner: the player with the unique lowest score.  None when the
            best score is tied (skin dies).
    """
    game            = models.ForeignKey(
                        MultiSkinsGame, on_delete=models.CASCADE,
                        related_name='hole_results',
                    )
    hole_number     = models.PositiveSmallIntegerField(
                        validators=[MinValueValidator(1), MaxValueValidator(18)]
                    )
    winner          = models.ForeignKey(
                        Player, on_delete=models.SET_NULL,
                        null=True, blank=True,
                        related_name='multi_skins_holes_won',
                    )

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        if self.winner:
            return f"Hole {self.hole_number} — {self.winner.name}"
        return f"Hole {self.hole_number} — dead"


class MultiSkinsLinkedRound(models.Model):
    """
    A foursome round LINKED into a cross-round Multi-Group Skins pool
    (docs/multi-skins-cross-round.md).

    The pool is anchored on a host round's `MultiSkinsGame`; other foursome
    rounds attach here so their gross scores feed the shared pool.  Which
    players in the linked round contribute is NOT stored — it is the
    phone-matched overlap of the pool roster with the round's players,
    resolved at scoring time.  The link record itself is the standing
    read grant for the linked round's scores (possible cross-account).

    Same-course + ≥1-overlap are enforced at creation (join endpoint).
    """
    game        = models.ForeignKey(
                    MultiSkinsGame, on_delete=models.CASCADE,
                    related_name='linked_rounds',
                )
    round       = models.ForeignKey(
                    Round, on_delete=models.CASCADE,
                    related_name='linked_skins_pools',
                    help_text="A round whose scores feed this pool.",
                )
    linked_by   = models.ForeignKey(
                    Player, on_delete=models.SET_NULL,
                    null=True, blank=True,
                    related_name='+',
                    help_text="Player who linked this round to the pool.",
                )
    created_at  = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ('game', 'round')

    def __str__(self):
        return f"Pool R{self.game.round_id} ← Round {self.round_id}"


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

NASSAU_VARIANT_CHOICES = [
    ('none',         'Standard Nassau'),
    ('tiebreak_2nd', '2nd-Ball Tie-Break'),
    ('claremont',    'Claremont'),
]

NASSAU_PRESS_SIDE_CHOICES = [
    ('top',    'Top (best-ball Nassau)'),
    ('bottom', 'Bottom (Claremont 2-pt game)'),
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

    Variants:
      none         — standard Nassau (default)
      tiebreak_2nd — when best balls tie, 2nd best ball breaks the tie
                     (foursomes only; 2-player games ignore this)
      claremont    — adds a simultaneous 2-point game (bottom bet):
                       Point 1 per hole = best ball
                       Point 2 per hole = 2nd best ball
                     Bottom also runs front9/back9/overall with its own
                     independent presses firing at ±2 bottom-points down.

    front9_result / back9_result / overall_result: set when each top bet concludes.
    bottom_front9_result / bottom_back9_result / bottom_overall_result:
        Claremont only — set when each bottom bet concludes.
    """
    # A foursome can hold MORE THAN ONE Nassau-family match at once — e.g. a
    # team Nassau AND a Singles Match with different teams (the "Larry case").
    # Each match is one row, discriminated by game_type; at most one row per
    # (foursome, game_type).  game_type is the same slug carried in
    # Round.active_games: 'nassau', 'nassau_nine', or 'match_18'.
    foursome            = models.ForeignKey(Foursome, on_delete=models.CASCADE, related_name='nassau_games')
    game_type           = models.CharField(
                            max_length=20,
                            choices=[
                                (GameType.NASSAU,      'Nassau'),
                                (GameType.NASSAU_NINE, 'Nassau Nine'),
                                (GameType.MATCH_18,    'Singles Match'),
                            ],
                            default=GameType.NASSAU,
                            help_text="Which Nassau-family match this row is; "
                                      "matches the Round.active_games slug.",
                        )
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
    # Optional per-side loss cap. Only meaningful once the match can escalate
    # (presses or Claremont); with neither, max loss is a fixed bet_unit × 3 so
    # no cap is needed. With 2 sides the cap is a simple clamp of the net total
    # to ±cap, and it also gates pressing (a side at the cap can't press —
    # see calculate_nassau / add_manual_press). Null = uncapped.
    loss_cap            = models.DecimalField(
                            max_digits=8, decimal_places=2, null=True, blank=True,
                            help_text="Per-side loss cap (presses/Claremont only); "
                                      "null = uncapped.",
                        )
    variant             = models.CharField(
                            max_length=20,
                            choices=NASSAU_VARIANT_CHOICES,
                            default='none',
                            help_text="Game variant: standard, 2nd-ball tie-break, or Claremont.",
                        )
    # Which of the three bets are live. Turning Front and Back off leaves an
    # Overall-only game — i.e. a straight 18-hole match.
    play_front          = models.BooleanField(default=True)
    play_back           = models.BooleanField(default=True)
    play_overall        = models.BooleanField(default=True)
    # "Nassau Nine": treat every hole PLAYED as one match segment (no front/back
    # split), so a single match + its presses run over the whole (often 9-hole)
    # round. The match is carried on the 'front' bet; back/overall are unused.
    single_match        = models.BooleanField(default=False)
    # Top (standard Nassau) results
    front9_result       = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    back9_result        = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    overall_result      = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    # Bottom (Claremont) results — null when variant != 'claremont'
    bottom_front9_result  = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    bottom_back9_result   = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    bottom_overall_result = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    status              = models.CharField(max_length=20, choices=MatchStatus.choices, default=MatchStatus.PENDING)

    class Meta:
        # At most one match of each type per foursome (a team Nassau + a Singles
        # Match can coexist; two team Nassaus cannot).
        unique_together = ('foursome', 'game_type')

    def __str__(self):
        return f"{self.get_game_type_display()} — Group {self.foursome.group_number}"


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
    front9_up_after / back9_up_after / overall_up_after track top-bet margins.

    Variant fields (null when variant == 'none'):
      team1_2nd_net / team2_2nd_net:
          Second-best adjusted score per team.  Set for 'tiebreak_2nd' and
          'claremont'; null for standard Nassau or 2-player matches.
      bottom_delta:
          Net bottom points earned by team1 on this hole: +2, +1, 0, -1, -2.
          Claremont only.
      bottom_front9_up_after / bottom_back9_up_after / bottom_overall_up_after:
          Running bottom-points margin.  Claremont only.
    """
    game                = models.ForeignKey(NassauGame, on_delete=models.CASCADE, related_name='hole_scores')
    hole_number         = models.PositiveSmallIntegerField()
    team1_best_net      = models.SmallIntegerField(null=True, blank=True)
    team2_best_net      = models.SmallIntegerField(null=True, blank=True)
    winner              = models.CharField(max_length=10, choices=NASSAU_RESULT_CHOICES, null=True, blank=True)
    # Running top margins within each nine
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
    # 2nd-ball fields (tiebreak_2nd + claremont variants only)
    team1_2nd_net       = models.SmallIntegerField(null=True, blank=True)
    team2_2nd_net       = models.SmallIntegerField(null=True, blank=True)
    # Claremont bottom fields
    bottom_delta        = models.SmallIntegerField(
                            null=True, blank=True,
                            help_text="Net bottom points for team1 this hole: +2..−2. Claremont only."
                        )
    bottom_front9_up_after    = models.SmallIntegerField(null=True, blank=True)
    bottom_back9_up_after     = models.SmallIntegerField(null=True, blank=True)
    bottom_overall_up_after   = models.SmallIntegerField(null=True, blank=True)

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.game}"


class NassauPress(models.Model):
    """
    A press bet within a NassauGame — either auto-triggered or manually called.

    nine:             'front' (holes 1-9) or 'back' (holes 10-18)
    side:             'top'    — standard best-ball Nassau press
                      'bottom' — Claremont 2-pt game press (fires at ±2 pts down)
    press_type:       'auto' (2-down trigger) or 'manual' (losing team)
    triggered_on_hole: hole after which the press was called
    start_hole:       first hole counted in this press
    end_hole:         last hole of that nine (9 for front, 18 for back)
    result:           set when the press concludes (None while active)
    holes_up:         final margin: +ve = team1 won.  For bottom presses this
                      is the net bottom-points margin (not hole count).
    """
    game                = models.ForeignKey(NassauGame, on_delete=models.CASCADE, related_name='presses')
    nine                = models.CharField(
                            max_length=5,
                            choices=[('front', 'Front 9'), ('back', 'Back 9')]
                        )
    side                = models.CharField(
                            max_length=10,
                            choices=NASSAU_PRESS_SIDE_CHOICES,
                            default='top',
                            help_text="'top' = Nassau best-ball press; 'bottom' = Claremont 2-pt press.",
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
        ordering = ['side', 'triggered_on_hole']

    def __str__(self):
        return (
            f"{self.get_press_type_display()} {self.side} press "
            f"hole {self.triggered_on_hole} ({self.nine}) — {self.game}"
        )


# ---------------------------------------------------------------------------
# IRISH RUMBLE (all foursomes vs each other, best N balls per segment)
# ---------------------------------------------------------------------------

class IrishRumbleConfig(models.Model):
    """
    Defines the Irish Rumble structure for a round.

    The `variant` field selects one of four named scoring patterns; the
    `segments` JSON is derived from the variant + course pars at setup
    time and stored verbatim so the scoring code stays variant-agnostic.

    Variants:
      * classic         — H1-6:1, H7-12:2, H13-17:3, H18:4 (original)
      * arizona_shuffle — H1-3:1, H4-6:2, H7-9:3, H10-12:1, H13-15:2, H16-18:3
      * shuffle         — Par-driven: P3→3 balls, P4→2 balls, P5→1 ball
      * custom          — TD picks per-hole balls-to-count (1-4)

    `custom_balls` stores the TD's 18-element list for the custom variant;
    it's null/empty for the named variants (segments are computed from
    variant + par at save time).

    For a 3-some foursome, balls_to_count is automatically capped at
    the number of real players in that group (phantom excluded from count).

    A double-bogey cap (max 2 over par per hole) is always applied before
    taking the best-N scores — this is the Stableford-style damage limiter.

    For strokes_off mode, the low handicap reference is the lowest
    playing_handicap across ALL foursomes in the round (not just within
    each group), so every player competes from the same baseline.
    """
    VARIANT_CHOICES = (
        ('classic',         'Classic'),
        ('arizona_shuffle', 'Arizona Shuffle'),
        ('shuffle',         'Shuffle (par-based)'),
        ('custom',          'Custom (per-hole)'),
    )

    round               = models.OneToOneField(Round, on_delete=models.CASCADE, related_name='irish_rumble_config')
    variant             = models.CharField(
                            max_length=20,
                            choices=VARIANT_CHOICES,
                            default='classic',
                            help_text=(
                                "Scoring pattern.  The segments JSON below is "
                                "derived from variant + course par at setup."
                            ),
                        )
    custom_balls        = models.JSONField(
                            null=True, blank=True,
                            help_text=(
                                "Custom variant: 18-element list of per-hole "
                                "balls-to-count (1-4 each).  Null for named variants."
                            ),
                        )
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
                            help_text="Entry fee per foursome; total pool = entry_fee × num_foursomes.",
                        )
    payouts             = models.JSONField(
                            default=list,
                            help_text=(
                                "Payout per finishing place. "
                                "Example: [{'place': 1, 'amount': 60.00}, "
                                "{'place': 2, 'amount': 30.00}]"
                            ),
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
    excluded_player_ids = models.JSONField(
                            default=list,
                            help_text=(
                                "Player IDs excluded from prize payouts. "
                                "Excluded players still appear in standings "
                                "so their score is visible, but they receive "
                                "no payout."
                            ),
                        )
    participant_player_ids = models.JSONField(
                            default=list,
                            help_text=(
                                "Player IDs actually IN this game (a SUBSET side "
                                "game — e.g. 2 of a 4-some). Empty = all real "
                                "players in the round. excluded_player_ids must "
                                "be a subset of these. See docs/parallel-games.md."
                            ),
                        )

    def __str__(self):
        return f"Low Net config — {self.round}"


class StablefordGame(models.Model):
    """
    Configuration for the casual Stableford game within a round.

    Points are awarded per hole by the player's score relative to par (net or
    gross), via an EDITABLE 6-bucket table. With the standard table
    (5/4/3/2/1/0) Stableford is identical in ranking to low-net-with-a-double-
    bogey-cap; the table is what lets it diverge (e.g. Modified Stableford
    8/5/2/0/-1/-3 rewarding birdies and penalising bogeys, including negatives).

    Money mirrors Low Net: an entry fee per player forms the pool, distributed
    to the top finishers per the `payouts` list; excluded players appear in
    standings but receive nothing.
    """
    round         = models.OneToOneField(
                        Round, on_delete=models.CASCADE,
                        related_name='stableford_config')
    # Net (variable %) or Gross only — Strokes-Off is intentionally not offered.
    handicap_mode = models.CharField(
                        max_length=20, choices=HandicapMode.choices,
                        default=HandicapMode.NET)
    net_percent   = models.PositiveSmallIntegerField(default=100)

    # Editable points table, keyed by score relative to par. Defaults are the
    # standard Stableford values; values may be negative (Modified Stableford).
    pts_albatross = models.SmallIntegerField(default=5)  # -3 or better
    pts_eagle     = models.SmallIntegerField(default=4)  # -2
    pts_birdie    = models.SmallIntegerField(default=3)  # -1
    pts_par       = models.SmallIntegerField(default=2)  #  0
    pts_bogey     = models.SmallIntegerField(default=1)  # +1
    pts_double    = models.SmallIntegerField(default=0)  # +2 or worse

    # Settlement style:
    #   pool      — entry-fee pool split among the top `places` (Low-Net style).
    #   per_point — no pool; each player settles vs every opponent at
    #               per_point_rate × the points margin ("pay everyone above you").
    PAYOUT_STYLES = [('pool', 'Pool (places paid)'), ('per_point', 'Per point')]
    payout_style   = models.CharField(max_length=12, choices=PAYOUT_STYLES,
                                      default='pool')
    per_point_rate = models.DecimalField(
                        max_digits=6, decimal_places=2, default=0.00,
                        help_text="$ per point of margin vs each opponent "
                                  "(per_point style).")
    # per_point settlement (all map to services.wager.settle):
    #   average — STANDARD: settle vs the field average (Points 5-3-1 economics)
    #   all     — pay everyone above you (= n × average; advanced)
    #   first   — only the leader(s) collect the margin (advanced)
    PER_POINT_MODES = [
        ('average', 'Settle vs the field average'),
        ('all',     'Pay everyone above you'),
        ('first',   'Pay first'),
    ]
    per_point_mode = models.CharField(max_length=8, choices=PER_POINT_MODES,
                                      default='average')
    # Optional per-player loss cap (per_point only). Null = uncapped. When set,
    # losers clip at the cap and winners reduce pro-rata (services.wager.settle).
    loss_cap       = models.DecimalField(
                        max_digits=8, decimal_places=2, null=True, blank=True,
                        help_text="Optional per-player loss cap (per_point "
                                  "style); null = uncapped.")

    entry_fee           = models.DecimalField(
                            max_digits=8, decimal_places=2, default=0.00,
                            help_text="Entry fee per player (pool style).")
    payouts             = models.JSONField(
                            default=list,
                            help_text="Payout per finishing place, e.g. "
                                      "[{'place': 1, 'amount': 60}].")
    excluded_player_ids = models.JSONField(default=list)
    # Player IDs actually IN this game (a SUBSET side game). Empty = all real
    # players in the round. excluded_player_ids ⊆ these. docs/parallel-games.md.
    participant_player_ids = models.JSONField(default=list)

    def points_for_diff(self, diff: int) -> int:
        """Stableford points for a net/gross score `diff` strokes over par."""
        if diff <= -3:
            return self.pts_albatross
        return {
            -2: self.pts_eagle,
            -1: self.pts_birdie,
            0:  self.pts_par,
            1:  self.pts_bogey,
        }.get(diff, self.pts_double)

    def __str__(self):
        return f"Stableford config — {self.round}"


class LowNetChampionshipConfig(models.Model):
    """
    Configuration for the Low Net Championship game spanning a full Tournament.

    Mirrors LowNetRoundConfig but scoped to a Tournament instead of a Round.
    The calculator aggregates each player's capped net total across every
    round in the tournament (rounds_to_count = None means all rounds count;
    N-of-M selection is deferred until a future release).

    A double-bogey cap (max 2 over par per hole) is always applied, matching
    the per-round behaviour.

    payouts is a JSON list defining the prize structure:
        [{"place": 1, "amount": 200.00}, {"place": 2, "amount": 100.00}, ...]
    entry_fee is per player; prize_pool = entry_fee × player_count.
    """
    tournament          = models.OneToOneField(
                            'tournament.Tournament',
                            on_delete=models.CASCADE,
                            related_name='low_net_championship_config',
                        )
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
                            help_text="Per-player entry fee.",
                        )
    payouts             = models.JSONField(
                            default=list,
                            help_text=(
                                "Payout per finishing place. "
                                "Example: [{'place': 1, 'amount': 200.00}, "
                                "{'place': 2, 'amount': 100.00}]"
                            ),
                        )

    def __str__(self):
        return f"Low Net Championship config — {self.tournament}"


class StablefordChampionshipConfig(models.Model):
    """
    Configuration for the Stableford Championship — total Stableford points
    accumulated across every round of a Tournament (all rounds count; N-of-M
    is deferred, matching the Low Net Championship). Mirrors the casual
    StablefordGame's scoring (editable 6-bucket table, Net% or Gross) but is
    scoped to the Tournament and is pool-paid (entry_fee + payouts).
    """
    tournament    = models.OneToOneField(
                        'tournament.Tournament', on_delete=models.CASCADE,
                        related_name='stableford_championship_config')
    handicap_mode = models.CharField(max_length=20, choices=HandicapMode.choices,
                                     default=HandicapMode.NET)
    net_percent   = models.PositiveSmallIntegerField(default=100)

    pts_albatross = models.SmallIntegerField(default=5)
    pts_eagle     = models.SmallIntegerField(default=4)
    pts_birdie    = models.SmallIntegerField(default=3)
    pts_par       = models.SmallIntegerField(default=2)
    pts_bogey     = models.SmallIntegerField(default=1)
    pts_double    = models.SmallIntegerField(default=0)

    entry_fee           = models.DecimalField(max_digits=8, decimal_places=2,
                                              default=0.00)
    payouts             = models.JSONField(default=list)
    excluded_player_ids = models.JSONField(default=list)

    def points_for_diff(self, diff: int) -> int:
        if diff <= -3:
            return self.pts_albatross
        return {-2: self.pts_eagle, -1: self.pts_birdie, 0: self.pts_par,
                1: self.pts_bogey}.get(diff, self.pts_double)

    def __str__(self):
        return f"Stableford Championship config — {self.tournament}"


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
    entry_fee   = models.DecimalField(
                      max_digits=8, decimal_places=2, default=0.00,
                      help_text="Entry fee per foursome; total pool = entry_fee × num_foursomes.",
                  )
    payouts     = models.JSONField(
                      default=list,
                      help_text=(
                          "Payout per finishing place. "
                          "Example: [{'place': 1, 'amount': 60.00}, "
                          "{'place': 2, 'amount': 30.00}]"
                      ),
                  )

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
    For a 4-some: standard single elimination (2 semis on holes 1-9;
    Final + 3rd Place match on holes 10-18).
    bracket_type: 'single_elim' only (three_player_points kept for legacy).

    entry_fee   — amount each real player pays into the prize pool.
    payout_config — JSON dict mapping place label to dollar amount, e.g.:
        {"1st": 48.00, "2nd": 24.00, "3rd": 8.00, "4th": 0.00}
    prize_pool is derived as entry_fee × number of real players and stored
    for display convenience.
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
    # Per-bracket handicap configuration so a match-play side game can use
    # Strokes-Off-Low (best golfer plays to 0) within the foursome even when
    # the round-wide handicap mode is set differently for other games like
    # Stroke Play.  Defaults to NET / 100 so existing brackets — which were
    # implicitly inheriting round.handicap_mode — keep their previous
    # behaviour after migration; new brackets explicitly carry the chosen
    # mode.  See services/tournament_match_play.py for the resolution rule.
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=HandicapMode.choices,
                            default=HandicapMode.NET,
                            help_text="Per-bracket handicap mode (net/gross/strokes_off).",
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            help_text="Percentage of handicap applied when mode=net (0–200).",
                        )
    entry_fee           = models.DecimalField(
                            max_digits=7, decimal_places=2, default=0.00,
                            help_text="Per-player entry fee for the match play prize pool."
                        )
    payout_config       = models.JSONField(
                            default=dict, blank=True,
                            help_text=(
                                'Dict of place → dollar amount. '
                                'E.g. {"1st": 48.00, "2nd": 24.00, "3rd": 8.00, "4th": 0.00}'
                            )
                        )

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


# ---------------------------------------------------------------------------
# THREE-PERSON MATCH (tournament game: 9-hole 5-3-1 seeding + 9-hole match play)
# ---------------------------------------------------------------------------

class ThreePersonMatch(models.Model):
    """
    Tournament game for a 3-player group.

    Nine holes of Points 5-3-1 scoring.  After hole 9, final standings are
    determined by cumulative points.  Tied positions are resolved by sudden-
    death match play on holes 10-18.  Phase 2 (leader vs runner_up) always
    calculates retroactively from hole 10 once both finalists are known.

    Payout: entry_fee × real players = prize pool, payout_config maps place
    labels ('1st', '2nd', '3rd') to dollar amounts; tied players split.
    """

    STATUS_PENDING     = 'pending'
    STATUS_IN_PROGRESS = 'in_progress'
    STATUS_TIEBREAK    = 'tiebreak'
    STATUS_PHASE2      = 'phase2'
    STATUS_COMPLETE    = 'complete'

    STATUS_CHOICES = [
        ('pending',     'Pending'),
        ('in_progress', 'In Progress'),
        ('tiebreak',    'Tiebreak'),
        ('phase2',      'Phase 2'),
        ('complete',    'Complete'),
    ]

    foursome            = models.OneToOneField(
                            Foursome, on_delete=models.CASCADE,
                            related_name='three_person_match',
                        )
    status              = models.CharField(
                            max_length=20,
                            choices=STATUS_CHOICES,
                            default='pending',
                        )
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=HandicapMode.choices,
                            default=HandicapMode.NET,
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            validators=[MinValueValidator(0), MaxValueValidator(200)],
                        )
    entry_fee           = models.DecimalField(
                            max_digits=7, decimal_places=2, default=0.00,
                            help_text="Per-player entry fee for the prize pool.",
                        )
    payout_config       = models.JSONField(
                            default=dict, blank=True,
                            help_text=(
                                "Dict of place → dollar amount. "
                                "E.g. {'1st': 48.00, '2nd': 24.00, '3rd': 0.00}"
                            ),
                        )

    # ── Seeding (set once phase 1 resolves) ──────────────────────────────────
    # The player who finished 1st in 5-3-1 phase.
    phase1_leader       = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='+',
                            help_text="1st-place finisher after the 5-3-1 phase.",
                        )
    # The player who will face the leader in match play (2nd-place seed).
    phase1_runner_up    = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='+',
                            help_text="2nd-place seed entering the match play phase.",
                        )
    # When status='tiebreak_23': the two players battling for the runner-up slot.
    phase1_tied_a       = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='+',
                            help_text="Tied-for-2nd candidate A (only set during tiebreak_23).",
                        )
    phase1_tied_b       = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='+',
                            help_text="Tied-for-2nd candidate B (only set during tiebreak_23).",
                        )

    # ── Phase 2 match play details ────────────────────────────────────────────
    # First hole of the pure 1v1 match play (usually 10, may be later after
    # a tiebreak extends past hole 9).
    phase2_start_hole   = models.PositiveSmallIntegerField(
                            null=True, blank=True,
                            help_text="First hole of the pure match play phase.",
                        )
    # Running margin accumulated during the tiebreak_23 best-ball match.
    # Positive = leader is ahead entering phase 2.
    phase2_carryover    = models.SmallIntegerField(
                            default=0,
                            help_text=(
                                "Best-ball match margin at the end of the "
                                "tiebreak_23 phase (+ve = leader ahead)."
                            ),
                        )

    # ── Final result ──────────────────────────────────────────────────────────
    match_winner        = models.ForeignKey(
                            Player, on_delete=models.SET_NULL,
                            null=True, blank=True,
                            related_name='three_person_match_wins',
                        )

    created_at          = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Three-Person Match — Group {self.foursome.group_number}"


class ThreePersonMatchP1HoleResult(models.Model):
    """
    Phase 1 (5-3-1) per-hole, per-player result.
    Created for every hole scored during the 5-3-1 phase (holes 1–9 plus
    any tiebreak-extension holes).  Mirrors Points531PlayerHoleResult so
    the same tie-split allocator can be reused.
    """
    game                = models.ForeignKey(
                            ThreePersonMatch, on_delete=models.CASCADE,
                            related_name='phase1_results',
                        )
    player              = models.ForeignKey(
                            Player, on_delete=models.CASCADE,
                            related_name='tpm_p1_hole_results',
                        )
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    net_score           = models.SmallIntegerField()
    points_awarded      = models.DecimalField(max_digits=4, decimal_places=2)

    class Meta:
        unique_together = ('game', 'player', 'hole_number')
        ordering        = ['hole_number', '-points_awarded']

    def __str__(self):
        return (
            f"TPM P1 Hole {self.hole_number} — {self.player.name} — "
            f"{self.points_awarded}pt"
        )


class ThreePersonMatchP2HoleResult(models.Model):
    """
    Match play hole results for the Three-Person Match.

    phase='tiebreak' — holes played during the tiebreak_23 concurrent phase.
        main_* fields track the best-ball match (leader vs best of tied_a/b).
        tb_*   fields track the sub-match (tied_a vs tied_b).
    phase='phase2'   — holes played in the pure 1v1 match play phase.
        main_* fields track the leader vs runner_up match.
        tb_*   fields are unused (null).

    main_leader_wins: True=leader won the hole, False=opponent won, None=halved.
    tb_a_wins:        True=tied_a won the hole, False=tied_b won, None=halved.
    main_margin_after / tb_margin_after:
        Running margin after this hole.  Positive = leader / tied_a is ahead.
    """
    PHASE_TIEBREAK = 'tiebreak'
    PHASE_PHASE2   = 'phase2'
    PHASE_CHOICES  = [('tiebreak', 'Tiebreak'), ('phase2', 'Phase 2')]

    game                = models.ForeignKey(
                            ThreePersonMatch, on_delete=models.CASCADE,
                            related_name='phase2_results',
                        )
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    phase               = models.CharField(max_length=10, choices=PHASE_CHOICES)

    # Main match (leader vs runner_up / best-ball)
    main_leader_net     = models.SmallIntegerField(null=True, blank=True)
    main_opp_net        = models.SmallIntegerField(
                            null=True, blank=True,
                            help_text=(
                                "During tiebreak: min(tied_a_net, tied_b_net). "
                                "During phase2: runner_up's net score."
                            ),
                        )
    main_leader_wins    = models.BooleanField(
                            null=True, blank=True,
                            help_text="True=leader wins hole, False=opp wins, None=halved.",
                        )
    main_margin_after   = models.SmallIntegerField(
                            default=0,
                            help_text="Running margin after hole (+ve = leader ahead).",
                        )

    # Tiebreak sub-match (only populated when phase='tiebreak')
    tb_a_net            = models.SmallIntegerField(null=True, blank=True)
    tb_b_net            = models.SmallIntegerField(null=True, blank=True)
    tb_a_wins           = models.BooleanField(
                            null=True, blank=True,
                            help_text="True=tied_a wins hole, False=tied_b wins, None=halved.",
                        )
    tb_margin_after     = models.SmallIntegerField(
                            default=0,
                            help_text="Sub-match margin after hole (+ve = tied_a ahead).",
                        )

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        return f"TPM P2 Hole {self.hole_number} [{self.phase}] — {self.game}"


# ---------------------------------------------------------------------------
# QUOTA NASSAU  (2-player Stableford-quota comparison, Nassau style)
# ---------------------------------------------------------------------------
#
# How quota works
# ~~~~~~~~~~~~~~~
# Each player has a personal quota = 36 − course_handicap_index.
# A player with quota 18 is expected to earn 18 Stableford points over
# 18 holes (i.e. every hole at bogey = 1 pt, par = 2 pts, etc.).
# Being above quota ≡ under par in traditional match-play terms;
# below quota ≡ over par.
#
# Nassau-style comparison
# ~~~~~~~~~~~~~~~~~~~~~~~
# Front 9:  compare (p1_stableford_f9 − quota/2) vs (p2_stableford_f9 − quota/2).
# Back 9:   compare (p1_stableford_b9 − quota/2) vs (p2_stableford_b9 − quota/2).
# Overall:  compare (p1_stableford_18 − quota)   vs (p2_stableford_18 − quota).
# Higher score-vs-quota wins the segment; equal = halved.
#
# Live progress display
# ~~~~~~~~~~~~~~~~~~~~~
# After hole H, a player's running score-vs-quota is:
#     stableford_thru_H − (quota × H / 18)
# This is the "against par" equivalent the UI shows as the round progresses.
#
# Multiple matches per foursome
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# A foursome with 2 players from each Ryder Cup team yields 2 cross-team
# matches per group (e.g. A1 vs B1 and A2 vs B2).  All live under one
# QuotaNassauGame container (one per foursome).
# ---------------------------------------------------------------------------

QUOTA_RESULT_CHOICES = [
    ('player1', 'Player 1'),
    ('player2', 'Player 2'),
    ('halved',  'Halved'),
]


class QuotaNassauGame(models.Model):
    """
    Container for all 1v1 Quota Nassau matches within a foursome.

    status rolls up from its QuotaNassauMatch children:
        pending     — no holes scored yet
        in_progress — at least one hole scored
        complete    — all matches through 18 holes
    """
    foursome   = models.ForeignKey(
                     Foursome, on_delete=models.CASCADE,
                     related_name='quota_nassau_games'
                 )
    status     = models.CharField(
                     max_length=20,
                     choices=MatchStatus.choices,
                     default=MatchStatus.PENDING
                 )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Quota Nassau — Group {self.foursome.group_number}"


class QuotaNassauMatch(models.Model):
    """
    A single 1v1 Quota Nassau match between two players.

    player1_quota / player2_quota store 36 − course_handicap_index at the
    time of setup so the match is immune to later handicap edits.

    Segment results ('player1' | 'player2' | 'halved') are set by
    calculate_quota_nassau(); null means the segment is not yet resolved.
    """
    game          = models.ForeignKey(
                        QuotaNassauGame, on_delete=models.CASCADE,
                        related_name='matches'
                    )
    player1       = models.ForeignKey(
                        Player, on_delete=models.PROTECT,
                        related_name='quota_nassau_as_p1'
                    )
    player2       = models.ForeignKey(
                        Player, on_delete=models.PROTECT,
                        related_name='quota_nassau_as_p2'
                    )
    player1_quota = models.SmallIntegerField(
                        help_text="36 − player1's course handicap index at setup time."
                    )
    player2_quota = models.SmallIntegerField(
                        help_text="36 − player2's course handicap index at setup time."
                    )
    front9_result  = models.CharField(
                         max_length=10, choices=QUOTA_RESULT_CHOICES,
                         null=True, blank=True
                     )
    back9_result   = models.CharField(
                         max_length=10, choices=QUOTA_RESULT_CHOICES,
                         null=True, blank=True
                     )
    overall_result = models.CharField(
                         max_length=10, choices=QUOTA_RESULT_CHOICES,
                         null=True, blank=True
                     )
    status         = models.CharField(
                         max_length=20,
                         choices=MatchStatus.choices,
                         default=MatchStatus.PENDING
                     )

    class Meta:
        unique_together = ('game', 'player1', 'player2')

    def __str__(self):
        return (
            f"{self.player1.short_name} (Q{self.player1_quota}) vs "
            f"{self.player2.short_name} (Q{self.player2_quota}) — {self.game}"
        )


class QuotaNassauHoleResult(models.Model):
    """
    Per-hole detail for a QuotaNassauMatch.

    Stableford points each player earned on this hole, plus running
    score-vs-quota accumulators used by the live-progress display.

    score_vs_quota_after
        Running (stableford_total − quota × hole / 18) for each player.
        Positive = above quota = under par equivalent.
        Negative = below quota = over par equivalent.

    front9_margin_after / back9_margin_after / overall_margin_after
        (p1_score_vs_quota − p2_score_vs_quota) after this hole within
        the relevant segment. Positive = player1 is ahead.
        Stored separately per nine so the UI can show independent segment
        progress bars without recomputing.
    """
    match        = models.ForeignKey(
                       QuotaNassauMatch, on_delete=models.CASCADE,
                       related_name='hole_results'
                   )
    hole_number  = models.PositiveSmallIntegerField(
                       validators=[MinValueValidator(1), MaxValueValidator(18)]
                   )
    p1_stableford          = models.SmallIntegerField(
                                 null=True, blank=True,
                                 help_text="Stableford points player1 earned this hole (0–5)."
                             )
    p2_stableford          = models.SmallIntegerField(
                                 null=True, blank=True,
                                 help_text="Stableford points player2 earned this hole (0–5)."
                             )
    # Running score-vs-quota for each player after this hole
    p1_score_vs_quota      = models.DecimalField(
                                 max_digits=6, decimal_places=2,
                                 null=True, blank=True,
                                 help_text=(
                                     "p1 cumulative stableford − (quota × hole/18). "
                                     "+ve = above quota, −ve = below."
                                 )
                             )
    p2_score_vs_quota      = models.DecimalField(
                                 max_digits=6, decimal_places=2,
                                 null=True, blank=True,
                             )
    # Segment running margins  (p1_score_vs_quota − p2_score_vs_quota)
    # Only the relevant nine is populated per hole (the other is null).
    front9_margin_after    = models.DecimalField(
                                 max_digits=6, decimal_places=2,
                                 null=True, blank=True,
                                 help_text="Front-9 margin after this hole (holes 1–9 only)."
                             )
    back9_margin_after     = models.DecimalField(
                                 max_digits=6, decimal_places=2,
                                 null=True, blank=True,
                                 help_text="Back-9 margin after this hole (holes 10–18 only)."
                             )
    overall_margin_after   = models.DecimalField(
                                 max_digits=6, decimal_places=2,
                                 null=True, blank=True,
                                 help_text="Overall (18-hole) running margin after this hole."
                             )

    class Meta:
        unique_together = ('match', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.match}"


# ---------------------------------------------------------------------------
# TRIPLE CUP  (One-Round Ryder Cup: 3 × 6-hole segments per foursome)
# ---------------------------------------------------------------------------
#
# A foursome plays a single 18-hole match split into three segments:
#   Holes 1–6   Fourball     — best-ball match play
#   Holes 7–12  Foursomes    — alternate-shot match play
#   Holes 13–18 Singles      — head-to-head match play (2 matches in 2v2)
#
# Number of matches scales by group size (per-match scoring model):
#   2v2: 4 matches (1 fourball + 1 foursomes + 2 singles) → 4 pv
#   2v1: 4 matches (solo carries every segment; phantom in fourball) → 4 pv
#   1v1: 3 matches (one per segment, all played as singles) → 3 pv
#
# Each match is recorded as a TripleCupMatch with its own two TripleCupTeams.
# Per-hole results live on TripleCupHoleResult.  Teams are fixed once the
# game is set up — no rotating-team logic like Sixes.
# ---------------------------------------------------------------------------

TRIPLE_CUP_SEGMENT_CHOICES = [
    ('fourball',  'Fourball'),
    ('foursomes', 'Foursomes (Alt-Shot)'),
    ('singles',   'Singles'),
]

TRIPLE_CUP_RESULT_CHOICES = [
    ('team1',  'Team 1'),
    ('team2',  'Team 2'),
    ('halved', 'Halved'),
]


class TripleCupGame(models.Model):
    """
    The One-Round Ryder Cup game for one Foursome.  Holds the shared
    config knobs; the actual matches and hole-by-hole results live on
    TripleCupMatch / TripleCupHoleResult rows.

    alt_shot_low_pct / alt_shot_high_pct
        Combined-team handicap formula for the foursomes (alt-shot)
        segment.  USGA default is 50% low + 50% high; we expose both
        knobs so a group can override to e.g. 0.6 × low + 0 × high
        without code changes.

    phantom_score_mode
        Only used in 2v1 (one player vs two) during the fourball
        segment.  The solo player's "team" needs a second ball, so we
        synthesise a phantom score per hole — net par by default.

    group_size
        Denormalised player count at setup time (2, 3, or 4).  The
        scorer reads this once instead of repeatedly counting real
        memberships, and it travels with the game across roster edits.
    """
    foursome            = models.OneToOneField(
                            Foursome, on_delete=models.CASCADE,
                            related_name='triple_cup_game',
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
    alt_shot_low_pct    = models.PositiveSmallIntegerField(
                            default=50,
                            validators=[MinValueValidator(0), MaxValueValidator(100)],
                            help_text="% of the lower partner's handicap used in foursomes (alt-shot).",
                        )
    alt_shot_high_pct   = models.PositiveSmallIntegerField(
                            default=50,
                            validators=[MinValueValidator(0), MaxValueValidator(100)],
                            help_text="% of the higher partner's handicap used in foursomes (alt-shot).",
                        )
    group_size          = models.PositiveSmallIntegerField(
                            default=4,
                            validators=[MinValueValidator(2), MaxValueValidator(4)],
                            help_text="Real-player count at setup: 2, 3, or 4.",
                        )
    foursomes_first     = models.BooleanField(
                            default=False,
                            help_text=(
                                "Play the foursomes (alt-shot) segment on holes "
                                "1-6 and fourball on 7-12.  Default False = "
                                "fourball first.  Singles is always 13-18."
                            ),
                        )
    created_at          = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Triple Cup — Group {self.foursome.group_number}"


class TripleCupMatch(models.Model):
    """
    One match within a TripleCupGame.

    For 2v2: match_number 1..4 → fourball / foursomes / singles A / singles B.
    For 2v1: match_number 1..4 → fourball (with phantom for the solo) /
                                 foursomes / solo-vs-p1 / solo-vs-p2.
    For 1v1: match_number 1..3 → segment 1 (1-6) / segment 2 (7-12) /
                                 segment 3 (13-18), all 'singles'.

    holes_up_after_final / finished_on_hole are written by the scorer
    when the match reaches a decided state (one side leads by more
    holes than remain).  result is null while the match is in progress
    or pending.
    """
    game                = models.ForeignKey(
                            TripleCupGame, on_delete=models.CASCADE,
                            related_name='matches',
                        )
    match_number        = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(4)],
                            help_text="1..4 within the game.",
                        )
    segment             = models.CharField(
                            max_length=20,
                            choices=TRIPLE_CUP_SEGMENT_CHOICES,
                        )
    label               = models.CharField(
                            max_length=40,
                            blank=True,
                            help_text="Display label e.g. 'Singles 1' or 'Match 2'.",
                        )
    start_hole          = models.PositiveSmallIntegerField()
    end_hole            = models.PositiveSmallIntegerField()
    status              = models.CharField(
                            max_length=20,
                            choices=MatchStatus.choices,
                            default=MatchStatus.PENDING,
                        )
    result              = models.CharField(
                            max_length=10,
                            choices=TRIPLE_CUP_RESULT_CHOICES,
                            null=True, blank=True,
                            help_text="Set when match is decided.",
                        )
    holes_up_after_final = models.SmallIntegerField(
                            default=0,
                            help_text="Final margin: +ve = team1 won, -ve = team2.",
                        )
    finished_on_hole    = models.PositiveSmallIntegerField(
                            null=True, blank=True,
                            help_text="Hole where the match was mathematically clinched.",
                        )
    # Alt-shot only: which player on each team tees off the first
    # hole of the foursomes segment.  The partner tees off the next
    # hole and they alternate from there.  Null for non-foursomes
    # segments and for the solo side of 2v1 (no alternation needed).
    team1_first_tee_player = models.ForeignKey(
                                Player, on_delete=models.SET_NULL,
                                null=True, blank=True,
                                related_name='+',
                                help_text="Foursomes only: team1 player who tees off the first segment hole.",
                            )
    team2_first_tee_player = models.ForeignKey(
                                Player, on_delete=models.SET_NULL,
                                null=True, blank=True,
                                related_name='+',
                                help_text="Foursomes only: team2 player who tees off the first segment hole.",
                            )

    class Meta:
        unique_together = ('game', 'match_number')
        ordering        = ['match_number']

    def __str__(self):
        return f"Match {self.match_number} ({self.segment}) — {self.game}"

    def active_player_id(self, team_number: int, hole_number: int) -> int | None:
        """For a foursomes match, return the player ID on *team_number*
        whose turn it is to play on *hole_number*.  Returns None when
        not a foursomes match or the first-tee-off player isn't set.
        Alternation: position = hole - start_hole; active = first-tee
        if position even, else the partner."""
        if self.segment != 'foursomes':
            return None
        first = (self.team1_first_tee_player_id if team_number == 1
                 else self.team2_first_tee_player_id)
        if first is None:
            return None
        team = next((t for t in self.teams.all()
                     if t.team_number == team_number), None)
        if team is None:
            return None
        pids = list(team.players.values_list('id', flat=True))
        if first not in pids:
            return None
        position = hole_number - self.start_hole
        if position < 0:
            return None
        if position % 2 == 0:
            return first
        # Solo side (1 real player) has no alternation — always the same.
        if len(pids) == 1:
            return pids[0]
        partner = next((p for p in pids if p != first), None)
        return partner


class TripleCupTeam(models.Model):
    """
    One side of a TripleCupMatch.  team_number is 1 or 2; players is the
    M2M of real players competing for that side in this match.

    Phantoms are never stored here — the phantom for 2v1 fourball is
    synthesised in the scorer from TripleCupGame.phantom_score_mode and
    doesn't need a Player row.
    """
    match               = models.ForeignKey(
                            TripleCupMatch, on_delete=models.CASCADE,
                            related_name='teams',
                        )
    team_number         = models.PositiveSmallIntegerField()  # 1 or 2
    players             = models.ManyToManyField(
                            Player,
                            related_name='triple_cup_teams',
                        )
    is_winner           = models.BooleanField(default=False)

    class Meta:
        unique_together = ('match', 'team_number')
        ordering        = ['team_number']

    def __str__(self):
        return f"Team {self.team_number} — {self.match}"


class TripleCupHoleResult(models.Model):
    """
    Per-hole result for a TripleCupMatch.

    team1_net / team2_net are the scores compared on this hole:
      - Fourball:   best (lowest) net of the team's real players.
                    In 2v1 fourball the solo side's net is
                    min(solo_net, phantom_score) per TripleCupGame
                    .phantom_score_mode.
      - Foursomes:  the team's single alt-shot net.  The gross comes
                    from whichever player on the team recorded a score
                    that hole (in true alt-shot only one does); the
                    handicap allotment uses the configured combined
                    formula (default 50%L + 50%H).
      - Singles:    the lone player's net.

    winning_team_number is 1, 2, or null on a halve.
    holes_up_after tracks the running match margin
    (positive = team1 leading).
    """
    match               = models.ForeignKey(
                            TripleCupMatch, on_delete=models.CASCADE,
                            related_name='hole_results',
                        )
    hole_number         = models.PositiveSmallIntegerField(
                            validators=[MinValueValidator(1), MaxValueValidator(18)]
                        )
    team1_net           = models.SmallIntegerField(null=True, blank=True)
    team2_net           = models.SmallIntegerField(null=True, blank=True)
    winning_team_number = models.PositiveSmallIntegerField(
                            null=True, blank=True,
                            help_text="1, 2, or null on halve.",
                        )
    holes_up_after      = models.SmallIntegerField(
                            default=0,
                            help_text="Running margin after this hole: +ve = team1 leading.",
                        )

    class Meta:
        unique_together = ('match', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.match}"


# ---------------------------------------------------------------------------
# LAS VEGAS (2v2 — team "number" per hole; lower number wins by the difference)
# ---------------------------------------------------------------------------

VEGAS_BIRDIE_MODE_CHOICES = (
    ('flip',       'Flip opponents on birdie'),
    ('multiplier', 'Multiply points on birdie'),
)
VEGAS_WINNER_CHOICES = (
    ('team1',  'Team 1'),
    ('team2',  'Team 2'),
    ('halved', 'Halved'),
)


class VegasGame(models.Model):
    """
    The Las Vegas game for one Foursome — 2v2, teams fixed at setup.

    Each hole, a team's "number" is its two NET scores with the low score as
    the tens digit and the high as the ones (each digit capped at 9). The lower
    number wins the hole and scores the *difference* of the two numbers.

    birdie_mode (gross birdie or better, per the round's gross scores):
      * flip       — any team's birdie reverses the OPPONENTS' digits (high→tens)
                     before the hole is decided, so even a trailing team's birdie
                     can swing it; both birdie → both flip.
      * multiplier — the WINNING team's best ball multiplies the points:
                     birdie ×2, eagle ×3, … (1 + under-par of its best ball),
                     no stacking; the loser's birdie does nothing.

    carryover (default off): a tied hole carries; the next decided hole scores
    difference × (carried_holes + 1), times any birdie multiplier.

    Settlement is 1-to-1 per player: each player's money = the running point
    differential × bet_unit (winners +, losers −), clipped by the optional
    per-side loss_cap (see services.wager.settle()). handicap_mode / net_percent
    / net_max_double_bogey are stored per-game so the match owns its policy.
    """
    foursome            = models.OneToOneField(
                            Foursome, on_delete=models.CASCADE,
                            related_name='vegas_game',
                        )
    status              = models.CharField(
                            max_length=20, choices=MatchStatus.choices,
                            default=MatchStatus.PENDING,
                        )
    handicap_mode       = models.CharField(
                            max_length=20, choices=HandicapMode.choices,
                            default=HandicapMode.NET,
                            help_text="How net scores (the digits) are derived.",
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            validators=[MinValueValidator(0), MaxValueValidator(200)],
                            help_text="Percent of playing handicap applied when handicap_mode='net'.",
                        )
    net_max_double_bogey = models.BooleanField(
                            default=True,
                            help_text="Cap each net hole score at net double bogey (par + 2).",
                        )
    birdie_mode         = models.CharField(
                            max_length=12, choices=VEGAS_BIRDIE_MODE_CHOICES,
                            default='flip',
                        )
    carryover           = models.BooleanField(
                            default=False,
                            help_text="Tied holes carry; next win × (carried + 1).",
                        )
    loss_cap            = models.DecimalField(
                            max_digits=8, decimal_places=2, null=True, blank=True,
                            help_text="Optional per-side max loss (in points × bet_unit); null = uncapped.",
                        )
    created_at          = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Las Vegas — Group {self.foursome.group_number}"


class VegasTeam(models.Model):
    """One of the two Vegas teams. team_number is 1 or 2; players are fixed."""
    game                = models.ForeignKey(
                            VegasGame, on_delete=models.CASCADE, related_name='teams')
    players             = models.ManyToManyField(Player, related_name='vegas_teams')
    team_number         = models.PositiveSmallIntegerField()   # 1 or 2

    def __str__(self):
        return f"Team {self.team_number} — {self.game}"


class VegasHoleResult(models.Model):
    """
    Per-hole Vegas result. team{1,2}_number are the EFFECTIVE numbers used to
    decide the hole (i.e. after any flip). points/multiplier/carry_count record
    how the winner's points were built.
    """
    game                = models.ForeignKey(
                            VegasGame, on_delete=models.CASCADE, related_name='hole_results')
    hole_number         = models.PositiveSmallIntegerField()
    team1_number        = models.PositiveSmallIntegerField(null=True, blank=True)
    team2_number        = models.PositiveSmallIntegerField(null=True, blank=True)
    winner              = models.CharField(
                            max_length=6, choices=VEGAS_WINNER_CHOICES,
                            null=True, blank=True)
    points              = models.PositiveSmallIntegerField(default=0)
    multiplier          = models.PositiveSmallIntegerField(default=1)
    carry_count         = models.PositiveSmallIntegerField(default=0)

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.game}"


# ---------------------------------------------------------------------------
# FOURBALL (2v2 best-ball match play, single 18-hole match within a foursome)
# ---------------------------------------------------------------------------

class FourballGame(models.Model):
    """
    The Fourball game for one Foursome — a single 18-hole 2v2 best-ball
    match between two fixed teams of two.

    Each hole, every player plays their own ball; the team's score for the
    hole is the BETTER (lower) of its two partners' scores (net / gross /
    strokes-off depending on handicap_mode).  Lower team score wins the hole
    (+1 up); a tie halves it.  The match closes out early once one team leads
    by more holes than remain (dormie / "3&2"), exactly like Match Play.

    Settlement is a single match bet: the winning team collects bet_amount
    per player (each winner +bet_amount, each loser −bet_amount, zero-sum);
    a halved match is a push.  bet_amount / handicap_mode / net_percent are
    stored per-game so the match owns its own policy.
    """
    foursome      = models.OneToOneField(
                        Foursome, on_delete=models.CASCADE,
                        related_name='fourball_game',
                    )
    status        = models.CharField(
                        max_length=20, choices=MatchStatus.choices,
                        default=MatchStatus.PENDING,
                    )
    handicap_mode = models.CharField(
                        max_length=20, choices=HandicapMode.choices,
                        default=HandicapMode.NET,
                        help_text="How each player's per-hole score is derived.",
                    )
    net_percent   = models.PositiveSmallIntegerField(
                        default=100,
                        validators=[MinValueValidator(0), MaxValueValidator(200)],
                        help_text="Percent of handicap applied for net / strokes-off modes.",
                    )
    bet_amount    = models.DecimalField(
                        max_digits=8, decimal_places=2, default=0,
                        help_text="Match stake per player; winners +, losers −, halve = push.",
                    )
    result        = models.CharField(
                        max_length=6, null=True, blank=True,
                        choices=[('team1', 'Team 1'), ('team2', 'Team 2'),
                                 ('halved', 'Halved')],
                    )
    holes_up_after_final = models.IntegerField(
                        default=0,
                        help_text="Final running margin (positive = Team 1 up).",
                    )
    finished_on_hole = models.PositiveSmallIntegerField(
                        null=True, blank=True,
                        help_text="Hole the match closed out on (null = went to 18).",
                    )
    created_at    = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Fourball — Group {self.foursome.group_number}"


class FourballTeam(models.Model):
    """One of the two Fourball teams. team_number is 1 or 2; players fixed."""
    game        = models.ForeignKey(
                    FourballGame, on_delete=models.CASCADE, related_name='teams')
    players     = models.ManyToManyField(Player, related_name='fourball_teams')
    team_number = models.PositiveSmallIntegerField()   # 1 or 2
    is_winner   = models.BooleanField(default=False)

    class Meta:
        unique_together = ('game', 'team_number')

    def __str__(self):
        return f"Team {self.team_number} — {self.game}"


class FourballHoleResult(models.Model):
    """
    Per-hole Fourball result.  team{1,2}_net are the team best-balls used to
    decide the hole; winning_team_number is 1, 2, or null on a halve.
    holes_up_after is the running match margin after this hole (positive =
    Team 1 up).
    """
    game                = models.ForeignKey(
                            FourballGame, on_delete=models.CASCADE,
                            related_name='hole_results')
    hole_number         = models.PositiveSmallIntegerField()
    team1_net           = models.IntegerField(null=True, blank=True)
    team2_net           = models.IntegerField(null=True, blank=True)
    winning_team_number = models.PositiveSmallIntegerField(null=True, blank=True)
    holes_up_after      = models.IntegerField(default=0)

    class Meta:
        unique_together = ('game', 'hole_number')
        ordering        = ['hole_number']

    def __str__(self):
        return f"Hole {self.hole_number} — {self.game}"
