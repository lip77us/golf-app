from django.db import models
from django.utils import timezone
from django.core.validators import MinValueValidator

from accounts.scoping import AccountScopedManager
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

    `account` is the tenant boundary — tournaments belong to one Account.
    """
    account             = models.ForeignKey(
                            'accounts.Account',
                            on_delete=models.CASCADE,
                            related_name='tournaments',
                            help_text="Tenant this tournament belongs to.",
                        )
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

    objects             = AccountScopedManager()

    def __str__(self):
        return self.name


class Round(models.Model):
    """
    A single day of golf. Can belong to a Tournament or stand alone.
    bet_unit is the dollar value of one unit for all games in this round.

    `account` is the tenant boundary — a Round always lives inside one
    Account.  For tournament rounds the account matches the parent
    Tournament's account; for casual rounds it's just the account that
    owns the data.  Stored directly on the Round (not just inherited
    via Tournament) because casual rounds have no tournament parent.
    """
    account             = models.ForeignKey(
                            'accounts.Account',
                            on_delete=models.CASCADE,
                            related_name='rounds',
                            help_text="Tenant this round belongs to.",
                        )
    tournament          = models.ForeignKey(
                            Tournament, on_delete=models.SET_NULL,
                            null=True, blank=True, related_name='rounds'
                        )
    round_number        = models.PositiveSmallIntegerField(default=1)
    date                = models.DateField(default=timezone.now)
    course              = models.ForeignKey(Course, on_delete=models.PROTECT, related_name='rounds')
    # --- Holes played (see docs/hole-flexibility.md) ----------------------
    # A round plays `num_holes` consecutive holes starting at `starting_hole`,
    # wrapping around the course's hole count. Defaults (18 from hole 1)
    # reproduce a standard round exactly. For shotgun starts each Foursome
    # overrides starting_hole; this is the round-level default. Derived play
    # order + segments live in services/hole_plan.py.
    num_holes           = models.PositiveSmallIntegerField(
                            default=18,
                            help_text="How many holes are played (e.g. 9 or 18).",
                        )
    starting_hole       = models.PositiveSmallIntegerField(
                            default=1,
                            help_text=(
                                "Hole the round starts on (1 = normal). "
                                "Foursome.starting_hole overrides per group for "
                                "shotgun starts."
                            ),
                        )
    status              = models.CharField(max_length=20, choices=RoundStatus.choices, default=RoundStatus.PENDING)
    active_games        = models.JSONField(
                            default=list,
                            help_text="List of GameType values active for this round."
                        )
    primary_game        = models.CharField(
                            max_length=40, null=True, blank=True,
                            help_text=(
                                "The casual round's PRIMARY game — the one that owns "
                                "score entry + configuration. Stored so the user's "
                                "explicit pick survives (active_games is an unordered "
                                "set; when two overlay games like Stroke Play + Skins "
                                "are both present, which is primary can't be derived). "
                                "Null = derive from active_games (tournament/legacy rounds)."
                            )
                        )
    game_point_values   = models.JSONField(
                            default=dict, blank=True,
                            help_text=(
                                "Cup point value per game type, e.g. "
                                '{"nassau": 1.0, "singles_nassau": 2.0}. '
                                "Used only for Cup rounds. Stored at wizard time and "
                                "applied per-foursome when the round is set up."
                            )
                        )
    cup_group_counts    = models.JSONField(
                            default=dict, blank=True,
                            help_text=(
                                "Number of groups (foursomes) playing each game type "
                                "in this cup round. Set at wizard time so total_possible "
                                "can be computed before the round is configured. "
                                'e.g. {"quota_nassau": 3} or {"irish_rumble": 2, "singles_nassau": 1}.'
                            )
                        )
    bet_unit            = models.DecimalField(max_digits=6, decimal_places=2, default=5.00)
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=[('gross','Gross'),('net','Net'),('strokes_off','Strokes Off Low')],
                            default='net',
                            help_text="Handicap mode applied to all games in this round.",
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            help_text="Percentage of handicap applied when mode=net (0–200).",
                        )
    net_max_double_bogey = models.BooleanField(
                            default=True,
                            help_text=(
                                "When true, every player's per-hole score in this "
                                "round is capped at net par + 2 for game-scoring "
                                "purposes (max-double-bogey rule). Applies only to "
                                "games whose handicap mode is Net or Strokes-Off; "
                                "gross-mode games are unaffected. Stored gross "
                                "scores are never modified. For tournament rounds, "
                                "set this via the Tournament-wide bulk action in "
                                "admin."
                            )
                        )
    scramble_config     = models.JSONField(
                            null=True, blank=True,
                            help_text=(
                                "Config for scramble if active. Example: "
                                "{'min_drives_per_player': 2, 'handicap_pct': 0.20}"
                            )
                        )
    notes               = models.TextField(blank=True)
    created_at          = models.DateTimeField(auto_now_add=True)
    created_by          = models.ForeignKey(
                            'core.Player',
                            on_delete=models.SET_NULL,
                            null=True, blank=True,
                            related_name='created_rounds',
                            help_text="Player who created this round. Only they may delete it."
                        )
    # Token used by the public /watch/<token>/ live-leaderboard page so
    # spectators can follow scores without logging in.  Auto-generated on
    # first save if missing (see Round.save() override below).
    watch_token         = models.CharField(
                            max_length=12,
                            unique=True,
                            blank=True,
                            null=True,
                            help_text=(
                                "Random short code used in the public "
                                "spectator URL: /watch/<token>/."
                            ),
                        )

    def save(self, *args, **kwargs):
        # Lazily mint a watch_token on first save.  base32 over 8 chars
        # gives 32**8 ≈ 1.1 trillion combinations — plenty for the
        # collision-free lifetime of a single tournament.
        if not self.watch_token:
            import secrets, string
            alphabet = string.ascii_uppercase + '23456789'  # base32-ish, no 0/1/I/O
            for _ in range(5):
                candidate = ''.join(secrets.choice(alphabet) for _ in range(8))
                if not Round.objects.filter(watch_token=candidate).exists():
                    self.watch_token = candidate
                    break
        super().save(*args, **kwargs)

    objects = AccountScopedManager()

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
    name                = models.CharField(
                            max_length=50, blank=True, default='',
                            help_text=(
                                "Optional custom name for this group/foursome "
                                "(e.g. a team name). Falls back to 'Group N' "
                                "when blank — see display_name."
                            )
                        )
    pink_ball_order     = models.JSONField(
                            default=list,
                            help_text="Ordered list of player PKs for pink ball rotation."
                        )
    active_games        = models.JSONField(
                            default=list,
                            help_text=(
                                "Games active for this specific foursome. "
                                "When empty the round-level active_games applies."
                            )
                        )
    has_phantom         = models.BooleanField(default=False)
    tee_time            = models.TimeField(
                            null=True, blank=True,
                            help_text="Scheduled tee time for this group (HH:MM)."
                        )
    # Shotgun start (see docs/hole-flexibility.md): this group's starting hole
    # (null = inherit the round's starting_hole). shotgun_slot is a DISPLAY-ONLY
    # tee-slot label (e.g. "A"/"B") rendered as "7A"/"7B" when more than one
    # group starts on the same hole; it has no effect on play order or scoring.
    starting_hole       = models.PositiveSmallIntegerField(
                            null=True, blank=True,
                            help_text=(
                                "Per-group shotgun start; null inherits the "
                                "round's starting_hole."
                            ),
                        )
    shotgun_slot        = models.CharField(
                            max_length=2, blank=True, default='',
                            help_text=(
                                "Display-only tee-slot label (e.g. 'A'/'B') when "
                                "multiple groups start on the same hole."
                            ),
                        )

    class Meta:
        unique_together = ('round', 'group_number')
        ordering = ['group_number']

    def real_players(self):
        return self.memberships.filter(player__is_phantom=False).select_related('player')

    def all_players(self):
        return self.memberships.all().select_related('player')

    def player_count(self):
        return self.memberships.filter(player__is_phantom=False).count()

    @property
    def display_name(self):
        """Custom name if set, else the default 'Group N' label."""
        return self.name.strip() if self.name.strip() else f"Group {self.group_number}"

    def __str__(self):
        return f"{self.display_name} — {self.round}"


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
    phantom_algorithm   = models.CharField(
                            max_length=50,
                            default='rotating_player_scores',
                            help_text='Algorithm id from scoring.phantom.REGISTRY.',
                        )
    phantom_config      = models.JSONField(
                            default=dict,
                            help_text='Algorithm-specific config (e.g. rotation order).',
                        )
    # Delegated scoring: a TD marks an on-app golfer in the foursome as its
    # scorer. A user whose verified phone matches this member's Player.phone may
    # then enter scores for this foursome (cross-account) and read the whole-
    # field leaderboard. Assignable any time (even day-of); ≥1 allowed.
    is_scorer           = models.BooleanField(
                            default=False,
                            help_text='This member scores for the foursome '
                                      '(delegated cross-account score entry).',
                        )
    # Mid-round withdrawal ("can't continue"). null = played all 18; N =
    # completed holes 1..N and is out for N+1..18. The player's stored
    # HoleScores for 1..N are kept and still settle; later holes are simply
    # not expected from them. Per-game settlement (Skins segments, Sixes
    # void/solo) keys off this field. See docs/mid-round-withdrawal.md.
    withdrew_after_hole = models.SmallIntegerField(
                            null=True, blank=True,
                            help_text='Last hole this player completed before '
                                      'withdrawing; null = played the full round.',
                        )
    # When the withdrawal interrupted a hole in progress, the group abandons
    # that hole (the one *after* withdrew_after_hole) for everyone. It scores
    # for nobody and its pot fraction evaporates in pool games. False = the
    # group played on cleanly and the next hole counts for the remaining
    # players. Only meaningful when withdrew_after_hole is set.
    withdrew_killed_next_hole = models.BooleanField(
                            default=False,
                            help_text='True if the hole after withdrawal was '
                                      'abandoned by the whole group (voided).',
                        )

    class Meta:
        unique_together = ('foursome', 'player')

    def handicap_strokes_on_hole(self, stroke_index, hole_number=None):
        """
        Returns the number of handicap strokes this player receives on a hole
        given the hole's stroke_index (1=hardest, 18=easiest).
        A playing handicap of 20 gives 1 stroke on holes SI 1–18 and
        2 strokes on holes SI 1–2.

        When ``hole_number`` is supplied, the allocation is PARTIAL-ROUND aware
        (a 9-hole / back-9 round scales + re-ranks the handicap over the holes
        played — see scoring.handicap.make_strokes_fn); for a full round this is
        identical to the plain SI formula. Callers that don't pass hole_number
        get the legacy full-round formula.

        Plus-handicappers (playing_handicap < 0) can produce a negative raw
        value; we clamp to 0 because the HoleScore field is non-negative and
        plus-handicap adjustments are handled separately if needed.
        """
        if hole_number is not None and self.tee_id is not None:
            from scoring.handicap import make_strokes_fn
            fn = make_strokes_fn(self.foursome)
            return max(0, fn(self.playing_handicap, self.tee, hole_number))
        full_strokes = self.playing_handicap // 18
        remainder = self.playing_handicap % 18
        extra = 1 if stroke_index <= remainder else 0
        return max(0, full_strokes + extra)

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


# ---------------------------------------------------------------------------
# TEAM TOURNAMENT  (Ryder Cup style — N teams, M players each)
# ---------------------------------------------------------------------------
#
# Design goals:
#   • Any number of teams (default 2 for Ryder Cup format).
#   • Any number of players per team — draft size is advisory, not enforced.
#   • Layers on top of the existing Tournament/Round/Foursome/Game stack;
#     nothing below is changed.
#   • Each round references existing GameType values so the organiser picks
#     from the full list of games already supported by the app.
# ---------------------------------------------------------------------------

# Reusable result choices for Ryder Cup segment outcomes.
RYDER_RESULT_CHOICES = [
    ('team1',  'Team 1'),
    ('team2',  'Team 2'),
    ('halved', 'Halved'),
]


# ── 1. TEAM SELECTION ────────────────────────────────────────────────────────

class TeamTournament(models.Model):
    """
    A Ryder Cup style team competition layered on top of a Tournament.

    Supports any number of teams (typically 2) of any size.
    players_per_team is a target for draft purposes — it is not enforced
    programmatically so organisers can start the tournament while the
    draft is still in progress.

    draft_complete should be set True when team rosters are locked.
    After that point the UI should prevent further player moves between teams.
    """
    tournament       = models.OneToOneField(
                           Tournament, on_delete=models.CASCADE,
                           related_name='team_tournament'
                       )
    cup_name         = models.CharField(
                           max_length=100,
                           default='Ryder Cup',
                           help_text=(
                               "Display name for the team competition — e.g. "
                               "'Ryder Cup', 'Presidents Cup', 'Bandon Cup'. "
                               "Shown in the app header and scoreboard."
                           )
                       )
    players_per_team = models.PositiveSmallIntegerField(
                           default=6,
                           help_text=(
                               "Target roster size per team. Advisory — the app "
                               "does not prevent uneven rosters."
                           )
                       )
    draft_complete   = models.BooleanField(
                           default=False,
                           help_text=(
                               "Set True to lock team rosters before play begins. "
                               "The UI should block player moves after this."
                           )
                       )
    created_at       = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Team Tournament — {self.tournament.name}"


class TournamentTeam(models.Model):
    """
    One team in a TeamTournament.

    team_number is 1-based (Team 1, Team 2, …).
    players is a many-to-many so any number of players can be assigned
    and the roster can be edited up until draft_complete is True.

    colour / short_code are optional display helpers for the mobile UI
    (e.g. colour="Blue", short_code="BLU").
    """
    tournament  = models.ForeignKey(
                      TeamTournament, on_delete=models.CASCADE,
                      related_name='teams'
                  )
    name        = models.CharField(max_length=100)
    team_number = models.PositiveSmallIntegerField()
    players     = models.ManyToManyField(
                      Player, related_name='tournament_teams', blank=True
                  )
    colour      = models.CharField(
                      max_length=50, blank=True,
                      help_text="Display colour name shown in the mobile UI."
                  )
    short_code  = models.CharField(
                      max_length=5, blank=True,
                      help_text="Up to 5-char abbreviation for scorecards (e.g. 'USA')."
                  )

    class Meta:
        unique_together = ('tournament', 'team_number')
        ordering        = ['team_number']

    def __str__(self):
        return f"{self.name} (Team {self.team_number}) — {self.tournament.tournament.name}"


# ── 2. ROUND / GAME SETUP ────────────────────────────────────────────────────

class RyderCupRoundConfig(models.Model):
    """
    Ryder Cup scoring layer for one Round.

    Links a Round to a TeamTournament and defines how Ryder Cup points
    are earned in that round.

    nassau_point_value  — points per Nassau-segment win (halves = half this).
    point_multiplier    — applied to every point earned in this round
                          (set > 1.0 to make later rounds worth more).
    notes               — organiser memo visible in the setup screen.
    """
    round              = models.OneToOneField(
                             Round, on_delete=models.CASCADE,
                             related_name='ryder_cup_config'
                         )
    tournament         = models.ForeignKey(
                             TeamTournament, on_delete=models.CASCADE,
                             related_name='round_configs'
                         )
    nassau_point_value = models.DecimalField(
                             max_digits=5, decimal_places=2, default='1.00',
                             help_text=(
                                 "Ryder Cup points awarded per Nassau-segment win. "
                                 "A halved segment gives each team half this value."
                             )
                         )
    point_multiplier   = models.DecimalField(
                             max_digits=5, decimal_places=2, default='1.00',
                             validators=[MinValueValidator('0.01')],
                             help_text=(
                                 "Multiplier applied to all points in this round. "
                                 "E.g. 2.0 makes every point worth double."
                             )
                         )
    notes              = models.TextField(blank=True)
    # Optional declaration of the game formats this round will contain.
    # Used to compute total_possible for rounds whose foursomes haven't been
    # configured yet, so that "pts needed to win" is correct from day one.
    #
    # Format: list of objects, one per game type in the round:
    #   [
    #     {"game_type": "quota_nassau", "units": 1, "point_value": "3.00"},
    #     {"game_type": "irish_rumble", "units": 1, "point_value": "3.00"},
    #     {"game_type": "singles_18",   "units": 1, "point_value": "1.00"}
    #   ]
    #
    # "units" means:
    #   nassau / quota_nassau / singles_nassau / singles_18 → number of foursomes
    #   irish_rumble                                         → number of pairings
    #                                                          (each pairing = 2 foursomes)
    #
    # Once the round's RyderCupFoursomeConfig records exist, the live computed
    # total_possible takes over automatically and this field is ignored.
    format_declarations = models.JSONField(
                              null=True, blank=True,
                              help_text=(
                                  "Declared game formats for this round. "
                                  "Used to compute total_possible before foursomes "
                                  "are configured. See model docstring for format."
                              )
                          )
    # Round-level format preset.  'custom' is the historic behaviour
    # (cup admin picks the game type per foursome in the setup
    # wizard).  'triple_cup' is the "One Day Ryder Cup" preset that
    # locks every foursome to the Triple Cup format (fourball +
    # alt-shot foursomes + 2 singles per foursome) so the admin
    # doesn't have to repeat the same pick 12 times.
    ROUND_FORMAT_CHOICES = [
        ('custom',     'Custom (per-foursome pick)'),
        ('triple_cup', 'One Day Ryder Cup (Triple Cup)'),
    ]
    round_format       = models.CharField(
                              max_length=20,
                              choices=ROUND_FORMAT_CHOICES,
                              default='custom',
                              help_text=(
                                  "Preset that drives the per-foursome game "
                                  "type at setup time.  'triple_cup' forces "
                                  "every foursome to Triple Cup."
                              ),
                          )

    def __str__(self):
        return f"Ryder Cup config — {self.round}"


class RyderCupFoursomeConfig(models.Model):
    """
    Per-foursome Ryder Cup setup for a round.

    game_type   — pick any GameType value the app supports (nassau,
                  quota_nassau, irish_rumble, match_play, …).
    team1/team2 — which TournamentTeams are competing in this foursome.
                  For games where both teams are in the same group (Nassau,
                  Quota Nassau, match_play): set both.
                  For Irish Rumble head-to-head (whole foursome = one team):
                  set team1 to the team whose players fill this foursome;
                  the cross-foursome pairing is recorded in
                  RyderCupIrishRumblePairing.

    A foursome can have only one active Ryder Cup game config (OneToOne).
    """
    foursome     = models.OneToOneField(
                       Foursome, on_delete=models.CASCADE,
                       related_name='ryder_cup_foursome_config'
                   )
    round_config = models.ForeignKey(
                       RyderCupRoundConfig, on_delete=models.CASCADE,
                       related_name='foursome_configs'
                   )
    game_type    = models.CharField(
                       max_length=30,
                       choices=GameType.choices,
                       help_text=(
                           "Game this foursome plays. Must be a GameType value "
                           "supported by the app (nassau, quota_nassau, "
                           "irish_rumble, match_play, etc.)."
                       )
                   )
    team1        = models.ForeignKey(
                       TournamentTeam, on_delete=models.CASCADE,
                       related_name='foursome_configs_as_t1',
                       null=True, blank=True
                   )
    team2        = models.ForeignKey(
                       TournamentTeam, on_delete=models.CASCADE,
                       related_name='foursome_configs_as_t2',
                       null=True, blank=True
                   )
    point_value  = models.DecimalField(
                       max_digits=5, decimal_places=2, default='1.00',
                       help_text=(
                           "Cup points awarded per match/segment win for this "
                           "group.  Overrides the round-level nassau_point_value "
                           "so that different game types can carry different weights "
                           "(e.g. Fourball = 2 pts, Singles = 1 pt)."
                       )
                   )

    def __str__(self):
        t1 = self.team1.name if self.team1 else '?'
        t2 = self.team2.name if self.team2 else '?'
        return (
            f"Group {self.foursome.group_number} — "
            f"{self.game_type} — {t1} vs {t2}"
        )


class RyderCupIrishRumblePairing(models.Model):
    """
    Links two foursomes for a head-to-head Irish Rumble comparison.

    In a Ryder Cup Irish Rumble round, each foursome is a homogeneous
    team (all 4 players on the same Ryder Cup team).  Two foursomes
    then compete against each other by comparing their accumulated
    Irish Rumble scores Nassau-style (F9 / B9 / Overall 18).

    Lower cumulative score wins each segment (stroke-play comparison).
    Segment results are stored here by calculate_ryder_cup_points()
    after scores are entered.
    """
    round_config   = models.ForeignKey(
                         RyderCupRoundConfig, on_delete=models.CASCADE,
                         related_name='irish_rumble_pairings'
                     )
    foursome_a     = models.OneToOneField(
                         Foursome, on_delete=models.CASCADE,
                         related_name='ryder_cup_rumble_as_a'
                     )
    foursome_b     = models.OneToOneField(
                         Foursome, on_delete=models.CASCADE,
                         related_name='ryder_cup_rumble_as_b'
                     )
    team_a         = models.ForeignKey(
                         TournamentTeam, on_delete=models.CASCADE,
                         related_name='rumble_pairings_as_a'
                     )
    team_b         = models.ForeignKey(
                         TournamentTeam, on_delete=models.CASCADE,
                         related_name='rumble_pairings_as_b'
                     )
    # Resolved by calculate_ryder_cup_points() — null until enough scores are in.
    front9_result  = models.CharField(
                         max_length=10, choices=RYDER_RESULT_CHOICES,
                         null=True, blank=True,
                         help_text="'team1'=team_a won the front 9."
                     )
    back9_result   = models.CharField(
                         max_length=10, choices=RYDER_RESULT_CHOICES,
                         null=True, blank=True,
                     )
    overall_result = models.CharField(
                         max_length=10, choices=RYDER_RESULT_CHOICES,
                         null=True, blank=True,
                     )

    def __str__(self):
        return (
            f"IR pairing: Grp {self.foursome_a.group_number} ({self.team_a.name}) "
            f"vs Grp {self.foursome_b.group_number} ({self.team_b.name})"
        )


# ── 3. RYDER CUP POINTS (score entry output) ─────────────────────────────────

class RyderCupMatchPoints(models.Model):
    """
    One row per Ryder Cup point-earning segment within a round.

    Every Nassau-style game produces up to 3 rows (front9, back9, overall).
    Singles matches also produce 3 rows but include player1/player2 to
    identify which players were paired.

    Source of the match is identified by exactly one of:
        foursome             — for within-group games (Nassau, Quota Nassau,
                               Match Play, singles Nassau).
        irish_rumble_pairing — for cross-group Irish Rumble matchups.

    team1_points + team2_points always sum to nassau_point_value × multiplier
    (or 0 if the segment is not yet resolved).
    """
    SEGMENT_CHOICES = [
        ('front9',  'Front 9'),
        ('back9',   'Back 9'),
        ('overall', 'Overall 18'),
        # Triple Cup — 4 matches per group.
        ('fourball',  'Fourball'),
        ('foursomes', 'Foursomes'),
        ('singles',   'Singles'),
    ]

    round_config         = models.ForeignKey(
                               RyderCupRoundConfig, on_delete=models.CASCADE,
                               related_name='match_points'
                           )
    team1                = models.ForeignKey(
                               TournamentTeam, on_delete=models.CASCADE,
                               related_name='ryder_points_as_t1'
                           )
    team2                = models.ForeignKey(
                               TournamentTeam, on_delete=models.CASCADE,
                               related_name='ryder_points_as_t2'
                           )
    # Source — exactly one should be non-null
    foursome             = models.ForeignKey(
                               Foursome, on_delete=models.SET_NULL,
                               null=True, blank=True,
                               related_name='ryder_cup_points'
                           )
    irish_rumble_pairing = models.ForeignKey(
                               RyderCupIrishRumblePairing, on_delete=models.SET_NULL,
                               null=True, blank=True,
                               related_name='match_points'
                           )
    # For singles matches: which two players were paired
    player1              = models.ForeignKey(
                               Player, on_delete=models.SET_NULL,
                               null=True, blank=True,
                               related_name='ryder_points_as_p1'
                           )
    player2              = models.ForeignKey(
                               Player, on_delete=models.SET_NULL,
                               null=True, blank=True,
                               related_name='ryder_points_as_p2'
                           )
    segment              = models.CharField(max_length=10, choices=SEGMENT_CHOICES)
    game_type            = models.CharField(max_length=30, choices=GameType.choices)
    result               = models.CharField(
                               max_length=10, choices=RYDER_RESULT_CHOICES,
                               null=True, blank=True
                           )
    team1_points         = models.DecimalField(max_digits=6, decimal_places=2, default=0)
    team2_points         = models.DecimalField(max_digits=6, decimal_places=2, default=0)

    class Meta:
        ordering = ['round_config', 'game_type', 'segment']

    def __str__(self):
        return (
            f"{self.segment} | {self.game_type} | "
            f"{self.team1.name} {self.team1_points} – "
            f"{self.team2.name} {self.team2_points}"
        )


# ---------------------------------------------------------------------------
# WATCHERS  (non-playing spectators invited to follow in-app, read-only)
# ---------------------------------------------------------------------------

class Watcher(models.Model):
    """
    A non-playing spectator invited to follow a round or tournament in the app
    (read-only leaderboard). Phone-matched like the rest of the friend model:
    when a user whose VERIFIED phone equals `phone` opens the app, the round /
    tournament surfaces in their "Shared with me". A tournament watcher follows
    the whole event; a (casual) round watcher follows that round.

    Exactly one of `round` / `tournament` is set. `phone` is stored normalized
    to E.164 so it can be compared to `User.phone` directly. Any participant of
    the round/tournament (not just the TD) may add watchers.
    """
    round       = models.ForeignKey(
                    'Round', null=True, blank=True, on_delete=models.CASCADE,
                    related_name='watchers')
    tournament  = models.ForeignKey(
                    'Tournament', null=True, blank=True, on_delete=models.CASCADE,
                    related_name='watchers')
    phone       = models.CharField(max_length=32, help_text='Normalized E.164.')
    name        = models.CharField(max_length=100, blank=True)
    invited_by  = models.ForeignKey(
                    'core.Player', null=True, blank=True,
                    on_delete=models.SET_NULL, related_name='+')
    created_at  = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=['round', 'phone'], name='uniq_round_watcher'),
            models.UniqueConstraint(
                fields=['tournament', 'phone'], name='uniq_tournament_watcher'),
        ]

    def __str__(self):
        target = self.tournament_id and f'tournament {self.tournament_id}' \
            or f'round {self.round_id}'
        return f'Watcher {self.phone} → {target}'


# ---------------------------------------------------------------------------
# MESSAGING (in-app feed: human chat + server event announcements)
# ---------------------------------------------------------------------------

class MessageThread(models.Model):
    """A message feed for a round (Phase 1). Audience = the round's participants
    across all foursomes + its watchers, resolved dynamically. Tournament- and
    team-scoped threads are later phases."""
    round = models.OneToOneField(
        Round, on_delete=models.CASCADE, related_name='message_thread',
        null=True, blank=True,
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f'MessageThread<round={self.round_id}>'


class Message(models.Model):
    """One message in a thread — either a human `user` post or a server `event`
    announcement (birdie, skin won, …) carrying a structured `data` payload."""
    KIND_USER = 'user'
    KIND_EVENT = 'event'
    KIND_CHOICES = ((KIND_USER, 'User'), (KIND_EVENT, 'Event'))

    thread = models.ForeignKey(
        MessageThread, on_delete=models.CASCADE, related_name='messages')
    kind = models.CharField(max_length=8, choices=KIND_CHOICES, default=KIND_USER)
    # Null author = system / event message.
    author = models.ForeignKey(
        Player, on_delete=models.SET_NULL, null=True, blank=True, related_name='+')
    body = models.TextField(blank=True)
    # Event payload (type, hole, player, value) — drives rich rendering + push.
    data = models.JSONField(default=dict, blank=True)
    # Idempotency for event messages (e.g. 'birdie:7:42'); blank for human chat.
    event_key = models.CharField(max_length=120, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ('created_at', 'id')
        indexes = [models.Index(fields=['thread', 'id'])]
        constraints = [
            models.UniqueConstraint(
                fields=['thread', 'event_key'],
                condition=~models.Q(event_key=''),
                name='uniq_thread_event_key',
            ),
        ]


class ThreadRead(models.Model):
    """Per-user read marker for a thread (drives unread counts)."""
    thread = models.ForeignKey(
        MessageThread, on_delete=models.CASCADE, related_name='reads')
    user = models.ForeignKey(
        'accounts.User', on_delete=models.CASCADE, related_name='thread_reads')
    last_read_message_id = models.PositiveBigIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=['thread', 'user'], name='uniq_thread_read'),
        ]
