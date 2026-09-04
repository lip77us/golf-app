from django.conf import settings
from django.db import models
from django.utils import timezone
from django.core.validators import MinValueValidator, MaxValueValidator

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
    # --- Individual-play scoring (docs/design-review/handoff-individual-play) --
    # Set ONCE for the tournament; every round and every board reads from here.
    # Cup tournaments ignore these (their scoring is per-round, per-format) and
    # keep the defaults.
    SCORING_METHODS     = [('stroke', 'Stroke play'), ('stableford', 'Stableford')]
    scoring_method      = models.CharField(
                            max_length=12, choices=SCORING_METHODS, default='stroke',
                            help_text=(
                                "Individual play: how the championship is scored. "
                                "One method, one board — a Stableford tournament "
                                "does not also draw a net stroke board."
                            ),
                        )
    # Net or Gross only. Strokes-off-low is a MATCH mechanism — it needs a single
    # opponent to anchor to — so it is not offered field-wide. It survives in
    # exactly one place: the Mini Singles Bracket, where it is the default.
    handicap_mode       = models.CharField(
                            max_length=20,
                            choices=[('gross', 'Gross'), ('net', 'Net')],
                            default='net',
                            help_text=(
                                "Individual play: field-wide handicap setting. The "
                                "day-bet DQ reads this — a net event disqualifies "
                                "the net money winners, a gross event the gross ones."
                            ),
                        )
    net_percent         = models.PositiveSmallIntegerField(
                            default=100,
                            help_text="Allowance applied when handicap_mode='net' (0–200).",
                        )
    # Mini Singles day 2 is funded by a percentage carved off the TOP of the
    # championship pool — there is no separate day-2 entry. 0 = no carve-out
    # (which is also the state when the bracket is switched off; nothing
    # downstream may assume the bracket exists).
    mini_singles_carve_pct = models.PositiveSmallIntegerField(
                            default=0,
                            help_text=(
                                "Percent of the championship pool carved out for "
                                "the Mini Singles day-2 champions' foursome. "
                                "0 = no carve-out."
                            ),
                        )
    created_at          = models.DateTimeField(auto_now_add=True)

    objects             = AccountScopedManager()

    @property
    def is_team_play(self) -> bool:
        """
        True for a Team Play tournament — many four-golfer teams, one round, one
        leaderboard (docs/design-review/handoff-team-play/SPEC.md). Like
        'team_cup' this is a client-set marker in active_games rather than a
        per-round GameType: the team layer sits on top of the round.
        """
        return 'team_play' in (self.active_games or [])

    @property
    def is_individual_play(self) -> bool:
        """
        True for an every-golfer-for-themselves tournament — the type the
        individual-play spec governs. The other two shapes are excluded by the
        presence of their own marker:

        * a **cup** keeps its own per-round, per-format scoring, and
        * **team play** scores a team rather than a golfer, sets its allowance
          from a format table rather than field-wide, and has exactly one round.

        Both would otherwise pick up the individual-play rules (always-on net
        double-bogey cap, field-wide allowance, best-N counting) purely by not
        being named here.
        """
        games = self.active_games or []
        return 'team_cup' not in games and 'team_play' not in games

    @property
    def counts_all_rounds(self) -> bool:
        """True when every round counts toward the championship."""
        return not self.rounds_to_count or self.rounds_to_count >= self.total_rounds

    @property
    def counting_rule_label(self) -> str:
        """The chip-strip string: 'All 4 rounds' / 'Best 3 of 4'."""
        if self.counts_all_rounds:
            n = self.total_rounds
            return f"All {n} round{'' if n == 1 else 's'}"
        return f"Best {self.rounds_to_count} of {self.total_rounds}"

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
    # Mini Singles day 2: the champions' foursome is DERIVED, never set. The
    # TD cannot know the four group winners when they builds Sunday's tee times,
    # so the groups step RESERVES a group here and services/mini_singles.py
    # swaps the winners into it once day 1 resolves. Everyone displaced takes
    # the seat the winner vacated, so tees and tee times stay intact.
    is_champions_foursome = models.BooleanField(
                            default=False,
                            help_text=(
                                "Reserved for the Mini Singles day-2 champions. "
                                "Filled from day 1, not by the TD."
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
    # An externally-managed event (Golf Genius, a club card) hands the golfer a
    # PLAYING handicap that is already post-allowance.  Set this and it is the
    # final number of strokes for the round: the golfer's index is ignored, and
    # the game's own allowance is NOT applied on top — doing so would
    # double-count the allowance the other system already applied.
    #
    # Null means "compute it", which is every round that Halved manages itself.
    # Per membership, so it dies with the round and never touches the roster —
    # the alternative people reach for is editing the index, which changes that
    # golfer everywhere and in every future round.
    playing_handicap_override = models.SmallIntegerField(
                            null=True, blank=True,
                            help_text=("Forced playing handicap from an "
                                       "external card. Final — no allowance "
                                       "is applied on top. Null = computed."),
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
    # Team Play: which team inside the playing group this golfer belongs to.
    #
    # **The foursome is the PLAYING group, not the team.**  That distinction
    # does not exist in a four-golfer event — the group is the team, everybody
    # sits at slot 1, and nothing here changes.  A pairs event puts TWO teams
    # in one group: four golfers, one tee time, one scorer, one card, and two
    # separate pairs on it.  Slot 2 is the second pair
    # (docs/design-review/handoff-team-pairs/SPEC.md §3).
    team_play_slot      = models.PositiveSmallIntegerField(
                            default=1,
                            help_text='1 or 2 — which pair inside the playing '
                                      'group. Always 1 for a foursome event, '
                                      'where the group IS the team.',
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
# TEAM PLAY  (the third tournament shape — many 4-golfer teams, ONE round)
# ---------------------------------------------------------------------------
#
# docs/design-review/handoff-team-play/SPEC.md
#
# Cup is two big sides and the unit is a match.  Individual is a field of
# singles and the unit is a card.  Team Play is many small teams, one
# leaderboard, one score per team per hole — the Saturday scramble a club runs
# most often, and deliberately the SIMPLEST of the three.
#
# Two structural calls worth knowing before reading the fields:
#
#   1. **A team IS a Foursome.**  TeamTournament/TournamentTeam are the CUP
#      roster layer (cup_name, players_per_team, draft_complete — two big sides
#      drafted before rounds exist) and are not reused.  A Team Play team is
#      one Foursome in the tournament's single Round, which brings tee times,
#      memberships with a stored course_handicap, delegated scoring, mid-round
#      withdrawal and watchers along for free.
#
#   2. **There is no round dimension anywhere.**  One round, stated rather than
#      chosen.  No round columns, no rounds_to_count, no per-round pot.  A club
#      wanting two days runs two tournaments.

class TeamPlayConfig(models.Model):
    """
    The TD's settings for a Team Play tournament — one row, set across wizard
    steps 3–7 and read by every surface afterwards.

    **Team size is a control, not a shape.**  Fours and pairs run the same
    wizard, the same leaderboard, the same pool and the same settlement; the
    size changes the format list and the allowance table, and nothing else in
    the flow knows about it
    (docs/design-review/handoff-team-pairs/SPEC.md §1).

    Six formats, but only TWO scorecards.  Four of the five pair formats end in
    one ball and take the scramble's card; best ball is a shamble whose count
    is 1.  Every format that chooses a tee shot carries the drive control —
    which is why the requirement applies across both sizes.
    """

    SIZE_FOURS = 4
    SIZE_PAIRS = 2
    SIZE_CHOICES = [
        (SIZE_FOURS, 'Fours'),
        (SIZE_PAIRS, 'Pairs'),
    ]

    FORMAT_SCRAMBLE       = 'scramble'
    FORMAT_SHAMBLE        = 'shamble'
    FORMAT_BEST_BALL      = 'best_ball'
    FORMAT_ALTERNATE_SHOT = 'alternate_shot'
    FORMAT_SCOTCH         = 'scotch'
    FORMAT_CHAPMAN        = 'chapman'
    FORMAT_CHOICES  = [
        (FORMAT_SCRAMBLE,       'Scramble'),
        (FORMAT_SHAMBLE,        'Shamble'),
        (FORMAT_BEST_BALL,      'Best ball'),
        (FORMAT_ALTERNATE_SHOT, 'Alternate shot'),
        (FORMAT_SCOTCH,         'Scotch'),
        (FORMAT_CHAPMAN,        'Chapman'),
    ]

    # Which formats each size may play.  `scramble` is the only one both sizes
    # run, and its ALLOWANCE is not shared — 25/20/15/10 on four golfers, 35/15 on
    # two.  Every table lookup is therefore keyed on (size, format), never on
    # the format alone.
    FORMATS_BY_SIZE = {
        SIZE_FOURS: (FORMAT_SCRAMBLE, FORMAT_SHAMBLE),
        SIZE_PAIRS: (FORMAT_SCRAMBLE, FORMAT_BEST_BALL, FORMAT_ALTERNATE_SHOT,
                     FORMAT_SCOTCH, FORMAT_CHAPMAN),
    }

    # The two card shapes.  Everything downstream branches on these rather than
    # on a format name: a card is either one number for the ball the team
    # played, or one number per golfer with the best N counting.
    ONE_BALL_FORMATS = (FORMAT_SCRAMBLE, FORMAT_ALTERNATE_SHOT,
                        FORMAT_SCOTCH, FORMAT_CHAPMAN)
    OWN_BALL_FORMATS = (FORMAT_SHAMBLE, FORMAT_BEST_BALL)

    # Shamble only.  The counts live UNDER the format radio, expanded in place
    # — house rule from the Irish Rumble work: no game gets a second rules
    # screen.
    COUNT_FIXED      = 'fixed'
    COUNT_ESCALATING = 'escalating'
    COUNT_PAR_BASED  = 'par_based'
    COUNT_PER_HOLE   = 'per_hole'
    COUNT_CHOICES    = [
        (COUNT_FIXED,      'Fixed'),
        (COUNT_ESCALATING, 'Escalating — by sixes'),
        (COUNT_PAR_BASED,  'Par-based'),
        (COUNT_PER_HOLE,   'Per hole'),
    ]

    # Three quotas and one schedule.  They are NOT four settings of one thing,
    # and that split decides the whole UI: a quota needs its slack shown, a
    # schedule needs one line on the tee.
    DRIVE_NONE        = 'none'
    DRIVE_PER_NINE    = 'per_nine'
    DRIVE_PER_18      = 'per_eighteen'
    DRIVE_ALTERNATING = 'alternating'
    DRIVE_CHOICES     = [
        (DRIVE_NONE,        'No requirement'),
        (DRIVE_PER_NINE,    'Per nine'),
        (DRIVE_PER_18,      'Per eighteen'),
        (DRIVE_ALTERNATING, 'Alternating pairs'),
    ]

    PENALTY_WARN       = 'warn'
    PENALTY_TWO_STROKE = 'two_strokes'
    PENALTY_CHOICES    = [
        (PENALTY_WARN,       'Warn only'),
        (PENALTY_TWO_STROKE, 'Two strokes per missing drive'),
    ]

    tournament = models.OneToOneField(
        Tournament, on_delete=models.CASCADE, related_name='team_play_config'
    )

    # ── Step 1 — the team size ───────────────────────────────────────────
    team_size = models.PositiveSmallIntegerField(
        default=SIZE_FOURS, choices=SIZE_CHOICES,
        help_text=(
            "Four or two.  It changes the format list on step 4 and the "
            "allowance table on step 6, and NOTHING else in the flow — same "
            "leaderboard, same payout, same settlement, same receipt.  "
            "Defaults to four, so every Foursome Play row reads unchanged."
        ),
    )

    # ── Step 3 — how a team makes a score ────────────────────────────────
    team_format = models.CharField(
        max_length=16, choices=FORMAT_CHOICES, default=FORMAT_SCRAMBLE,
        help_text=(
            "Fours: scramble (all four hit, best ball played, ONE score a "
            "hole) or shamble (best drive, then each golfer plays their own ball "
            "in, FOUR scores a hole).  Pairs: scramble, best ball, alternate "
            "shot, Scotch or Chapman — four of the five end in one ball, and "
            "best ball is the only one entering two scores."
        ),
    )
    ball_count_mode = models.CharField(
        max_length=12, choices=COUNT_CHOICES, default=COUNT_FIXED,
        help_text=(
            "Shamble only: how many of the four scores count on a hole. "
            "'escalating' is a PRESET rather than a grid recipe — it is the "
            "shape people describe in words ('sixes'), and making them tap "
            "eighteen cells for it is the app failing to listen."
        ),
    )
    ball_count_fixed = models.PositiveSmallIntegerField(
        default=2,
        validators=[MinValueValidator(1), MaxValueValidator(4)],
        help_text="Count used by ball_count_mode='fixed'. Best 2 of 4 is the default.",
    )
    ball_counts = models.JSONField(
        default=dict, blank=True,
        help_text=(
            "ball_count_mode='per_hole' only: {'1': 2, '2': 2, …} for holes "
            "1-18.  A hole set to 4 is legal and flagged — no drop score, so "
            "one blow-up is the team's."
        ),
    )

    # ── Step 4 — drives ──────────────────────────────────────────────────
    drive_rule = models.CharField(
        max_length=12, choices=DRIVE_CHOICES, default=DRIVE_NONE,
        help_text="Applies to BOTH formats — a shamble chooses a tee shot exactly as a scramble does.",
    )
    drives_required = models.PositiveSmallIntegerField(
        default=1,
        help_text=(
            "Quota rules only: drives owed per golfer per WINDOW (per nine, or "
            "per eighteen).  A short team owes four golfers' worth, not three — "
            "the phantom's share rotates through the three real golfers."
        ),
    )
    drive_penalty = models.CharField(
        max_length=12, choices=PENALTY_CHOICES, default=PENALTY_WARN,
        help_text=(
            "Falling short costs NOTHING by default.  Two strokes per missing "
            "drive is opt-in and applied to the team's gross at the end of the "
            "round.  Silently disqualifying a team over a drive count would be "
            "the worst outcome the app could produce.  Does not apply to the "
            "alternating-pairs schedule — there is nothing to fall short of."
        ),
    )

    # ── Step 5 — handicap & allowance ────────────────────────────────────
    handicap_mode = models.CharField(
        max_length=10,
        choices=[('net', 'Net'), ('gross', 'Gross')],
        default='net',
        help_text="Strokes-off-low needs a single opponent to anchor to and is not offered.",
    )
    allowance_override_pct = models.PositiveSmallIntegerField(
        null=True, blank=True,
        help_text=(
            "null = the format's table (scramble 25/20/15/10 lowest-first "
            "summed; shamble one percentage of each golfer's own, tracking the "
            "ball-count average).  Set to override with ONE flat percentage — "
            "a group's tradition beats the table.  The allowance is a table, "
            "not a preference: presenting it as an open question invites a guess."
        ),
    )

    # ── Step 7 — entry & payout ──────────────────────────────────────────
    entry_fee = models.DecimalField(
        max_digits=8, decimal_places=2, default=0,
        help_text="Per golfer, flat, taken at signup. Stepped in $5 on screen — nobody charges $23.",
    )
    places_paid = models.PositiveSmallIntegerField(
        default=3,
        validators=[MinValueValidator(1), MaxValueValidator(4)],
        help_text=(
            "Capped at the team count on screen.  Half the field cashing is "
            "ADVICE, not a rule — winner-takes-all is a legitimate preset."
        ),
    )
    split_pcts = models.JSONField(
        default=list, blank=True,
        help_text=(
            "[50, 30, 20] — one entry per paid place, and it MUST total 100. "
            "A split adding to 95 leaves money in the TD's pocket with no line "
            "explaining it, so Save is blocked with the shortfall named in "
            "dollars."
        ),
    )

    # ── Lock ─────────────────────────────────────────────────────────────
    format_locked_at = models.DateTimeField(
        null=True, blank=True,
        help_text=(
            "Stamped by the first score.  Format and ball counts lock together: "
            "a one-number card cannot be re-read as four, and a hole scored "
            "under 'best 2' cannot be re-read as 'best 1'."
        ),
    )
    created_at = models.DateTimeField(auto_now_add=True)

    @property
    def is_scramble(self) -> bool:
        return self.team_format == self.FORMAT_SCRAMBLE

    @property
    def is_shamble(self) -> bool:
        return self.team_format == self.FORMAT_SHAMBLE

    @property
    def is_pairs(self) -> bool:
        return self.team_size == self.SIZE_PAIRS

    @property
    def plays_one_ball(self) -> bool:
        """
        One number for the ball the team played — scramble, alternate shot,
        Scotch and Chapman.

        Scoring branches on THIS rather than on `is_scramble`: four of the five
        pair formats take the scramble's card, and a check for the format name
        would have needed widening in eleven places every time one was added.
        """
        return self.team_format in self.ONE_BALL_FORMATS

    @property
    def plays_own_ball(self) -> bool:
        """
        One number per golfer with the best N counting — shamble and best ball.

        **Best ball is a shamble whose count is 1.**  Two golfers, one score
        counting, and every consumer of the ball-count dict works untouched:
        best-1 on a par 4 is a par of 4, which is right.
        """
        return self.team_format in self.OWN_BALL_FORMATS

    @property
    def counts_every_ball(self) -> bool:
        """True when the ball count is fixed by the format rather than set by
        the TD. Best ball is always best-1-of-2; only the shamble has a dial."""
        return self.team_format == self.FORMAT_BEST_BALL

    @property
    def format_allowed(self) -> bool:
        """Is this format legal at this team size? Enforced by the setup
        endpoint — a two-golfer shamble and a four-golfer Chapman are both nonsense
        and neither should be reachable by an API caller."""
        return self.team_format in self.FORMATS_BY_SIZE.get(self.team_size, ())

    @property
    def is_locked(self) -> bool:
        """True once a score has landed. The format may no longer change."""
        return self.format_locked_at is not None

    @property
    def drive_rule_is_quota(self) -> bool:
        """
        Per nine and per eighteen are quotas — satisfied whenever you like, so
        the useful number is how much room is LEFT.  Alternating pairs is a
        schedule: no slack, no counting, nothing to fall short of.
        """
        return self.drive_rule in (self.DRIVE_PER_NINE, self.DRIVE_PER_18)

    @property
    def drive_rules_allowed(self) -> tuple:
        """
        The tee-shot control does three different jobs, and the format decides
        which (docs/design-review/handoff-team-pairs/SPEC.md §5).

        * **A record** — scramble, either size.  Compliance against a quota.
        * **An instruction** — Scotch.  Picking the drive says who hits next,
          so the tap happens on every hole; a quota is available ON TOP because
          the tap is already there, and it is off by default.
        * **A rota** — alternate shot.  Odd/even, set on the 1st tee, fixed for
          eighteen.  Not a quota: nothing to fall short of, so no warning and
          no penalty setting.
        * **Absent** — best ball and Chapman.  Both golfers drive every hole with
          no choice to record.

        Alternating pairs stays a fours rule: two golfers have no pairs to
        alternate, and their alternate-shot rota is the odd/even tee order,
        which is the `alternate_shot` format's own schedule.
        """
        if self.team_format in (self.FORMAT_BEST_BALL, self.FORMAT_CHAPMAN):
            return (self.DRIVE_NONE,)
        if self.team_format == self.FORMAT_ALTERNATE_SHOT:
            return (self.DRIVE_ALTERNATING,)
        if self.is_pairs:
            return (self.DRIVE_NONE, self.DRIVE_PER_NINE, self.DRIVE_PER_18)
        return (self.DRIVE_NONE, self.DRIVE_PER_NINE, self.DRIVE_PER_18,
                self.DRIVE_ALTERNATING)

    @property
    def drive_window_holes(self) -> int:
        """Holes one quota window covers. Per nine is TWO windows of nine; the
        front does not carry to the back."""
        return 9 if self.drive_rule == self.DRIVE_PER_NINE else 18

    @property
    def max_drives_per_golfer(self) -> int:
        """
        The most one golfer can be asked for in a window: the holes in it,
        divided between the golfers.

        **It scales with the team size.**  Four golfers sharing nine holes top out
        at two each, and four each across eighteen — which is where the shipped
        figures came from.  TWO golfers sharing the same nine top out at **four
        each**, and **nine each across eighteen**: every hole spoken for and
        nothing left over.

        Above this the quota is impossible before a ball is struck, which is a
        different thing from the shortfall the tracker warns about — that one
        the team chose.
        """
        return max(1, self.drive_window_holes // max(1, self.team_size))

    @property
    def requires_drive_pick(self) -> bool:
        """
        Whether a hole is incomplete until the drive is picked.

        **Only when a quota is counting them.**  With no drive requirement
        there is nothing to record, in any format — a pair playing Scotch knows
        which of them is hitting the second shot without telling the app, and
        charging them a tap a hole to be told back is the app asking for its
        own benefit.
        """
        return self.drive_rule_is_quota

    def __str__(self):
        return f"Team Play — {self.tournament.name} — {self.get_team_format_display()}"


class TeamPlayTeamState(models.Model):
    """
    Per-team state for Team Play — one row per TEAM, which is not always one
    row per group.

    **The foursome is the playing group.**  In a four-golfer event the group IS
    the team, there is one row at slot 1, and everything reads as it always
    did.  A pairs event puts two teams in one playing group — four golfers, one
    tee time, one scorer, one card — so it gets a row at slot 1 and another at
    slot 2, and each carries its own name, colour, figure and rota.

    ``colour`` is assigned whether or not the TD renames the team, because it
    does real work on the leaderboard and the scorecard: six team names, most
    of them one syllable and all unfamiliar, and the colour block is how a golfer
    finds their team without reading.
    """

    foursome = models.ForeignKey(
        Foursome, on_delete=models.CASCADE, related_name='team_play_states'
    )
    slot = models.PositiveSmallIntegerField(
        default=1,
        help_text='1 or 2 — which team inside the playing group. Always 1 for '
                  'a foursome event, where the group IS the team.',
    )
    # A pair's own name. A FOURSOME keeps using `Foursome.name`, because there
    # the group and the team are the same thing and that is the field the hub,
    # the tee sheet and the chat header already read. Two pairs in one group
    # cannot share one field, so theirs lives here.
    name = models.CharField(
        max_length=32, blank=True,
        help_text=(
            'Pairs only — a foursome names itself through Foursome.name. '
            'Longer than the ball game\'s 16 because this one is not invented: '
            'it is two real surnames, and "Petersen & Reilly" is seventeen '
            'characters before anybody has typed anything.'
        ),
    )
    colour = models.CharField(
        max_length=20, blank=True,
        help_text="Pine, Clay, Slate, Dune, Fern, Rust — the default team name and the row's identity.",
    )

    # True until the TD types a name over it.
    #
    # **A pair defaults to its two surnames** — `Maiolini & Yau`. That is not
    # the app inventing a name the way a colour would be: it is the only thing
    # anybody calls a pair, and two surnames fit on a leaderboard row where
    # four do not.  So the default is WRITTEN to ``Foursome.name``, and this
    # flag is what lets it follow a roster change until somebody overrides it.
    # A foursome keeps `Group N` and never writes anything here.
    name_is_default = models.BooleanField(
        default=True,
        help_text=(
            "False once the TD names the team themselves, after which the roster "
            "may change without the name following it."
        ),
    )

    # The team figure and the number that explains it.  Rounded ONCE, on the
    # total: rounding each golfer's contribution first turns 1.00+1.60+1.65+1.90
    # into 7, where rounding the sum gives 6.  Half rounds up.
    team_handicap = models.SmallIntegerField(
        null=True, blank=True,
        help_text="Whole strokes. Golfers do not play 6.15, and it looks like a spreadsheet error at the scoring table.",
    )
    team_handicap_raw = models.DecimalField(
        max_digits=6, decimal_places=2, null=True, blank=True,
        help_text="The full-precision sum, shown UNDER the rounded figure so the TD sees where it came from.",
    )

    # Alternating-pairs rule only.  Set by the team on the 1st tee, before the
    # first score, then FIXED for eighteen holes — a rota that can be re-cut
    # mid-round is not a rota.  The app does not derive it from handicap: four
    # golfers decide in ten seconds and would override a computed pairing anyway.
    drive_pairs = models.JSONField(
        default=list, blank=True,
        help_text=(
            "[[player_id, player_id], [player_id, player_id]] for four golfers; "
            "three golfers run AB / BC / AC repeating, stored as three pairs.  "
            "Immutable once written."
        ),
    )
    drive_pairs_set_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        unique_together = ('foursome', 'slot')
        ordering = ['foursome_id', 'slot']

    @property
    def pairs_are_set(self) -> bool:
        return bool(self.drive_pairs)

    def __str__(self):
        return (f"Team Play state — {self.foursome.display_name} "
                f"slot {self.slot} — {self.colour}")


class TeamDrivePick(models.Model):
    """
    Whose tee shot the team used on one hole.

    **One model serves both formats.**  A shamble has no ScrambleHoleScore row
    to hang a chosen_player off, and a single source makes the tracker one
    query either way.

    The pick never blocks the tap — the team may knowingly take the shortfall,
    and by default a shortfall costs nothing.
    """

    foursome = models.ForeignKey(
        Foursome, on_delete=models.CASCADE, related_name='team_drive_picks'
    )
    # Which team in the playing group took this drive. Two pairs sharing a
    # group each choose their own tee shot on every hole, so the pick is the
    # TEAM's and not the group's.
    slot = models.PositiveSmallIntegerField(default=1)
    hole_number = models.PositiveSmallIntegerField(
        validators=[MinValueValidator(1), MaxValueValidator(18)]
    )
    player = models.ForeignKey(
        Player, on_delete=models.CASCADE, related_name='team_drives_used',
        help_text="The golfer whose drive was played. Never the phantom — the phantom has no tee shot.",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ('foursome', 'slot', 'hole_number')
        ordering = ['hole_number']

    def __str__(self):
        return (f"Drive — {self.foursome.display_name} slot {self.slot} — "
                f"Hole {self.hole_number} — {self.player.name}")

# ---------------------------------------------------------------------------
# LIVE ACTIVITY TOKENS  (iOS lock-screen updates)
# ---------------------------------------------------------------------------

class LiveActivityToken(models.Model):
    """One golfer's Live Activity push token for one round.

    This is the **activity's** token, not the device's. Live Activity updates
    are an APNs push type addressed to a token iOS issues per activity, and it
    may be reissued mid-round — so the app sends it every time it changes and
    this row is upserted rather than appended to.

    It is per (round, user) because all four golfers in a Sixes foursome run
    their own activity showing the same board, and each needs addressing
    separately. The only slot that differs between them is the money line.

    Rows die with the round: an activity iOS has ended cannot be updated, and a
    stale token is a push that silently goes nowhere.
    """

    round      = models.ForeignKey(
                     Round, on_delete=models.CASCADE,
                     related_name='live_activity_tokens')
    user       = models.ForeignKey(
                     settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                     related_name='live_activity_tokens')
    # TextField, not CharField: a Live Activity token is much longer than a
    # device token (~320 hex chars in practice) and Apple documents no fixed
    # length, so any cap here is a 500 waiting for the next iOS release. The
    # 200 this started as rejected every real token with a DataError.
    token      = models.TextField(
                     help_text='Hex APNs token for this activity.')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ('round', 'user')

    def __str__(self):
        return f'Live Activity — round {self.round_id} — {self.user_id}'


class LiveActivityStartToken(models.Model):
    """One device's push-to-start token.

    Not the same thing as `LiveActivityToken`, and the difference is the whole
    point of this table.  That one addresses an activity that is ALREADY
    running, and only the phone that started it can hand one over — which is
    why, until this existed, the only golfer with a lock screen was the one
    entering scores.  The scorer is the one man in the group who least needs a
    board: he is holding the phone.

    iOS issues THIS token per app install, for an activity TYPE, whether or not
    anything is running.  The server can address it to raise a card on a phone
    that has done nothing — which is what puts the board on the other three
    golfers' lock screens, and on a watcher's.

    Per (user, token) rather than per round: one row serves every round that
    user ever plays, and a golfer with a phone and an iPad has two.  Rows are
    replaced when iOS reissues, and cleared on sign-out.

    iOS 17.2+ only.  An older phone simply never posts one, and gets exactly
    the behaviour it has today: a board if it scores, nothing if it doesn't.
    """

    user       = models.ForeignKey(
                     settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                     related_name='live_activity_start_tokens')
    token      = models.TextField(unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f'Live Activity start token — {self.user_id}'


class LiveActivityStartPush(models.Model):
    """One record of "we asked this phone to raise a card for this round".

    Exists to stop a start push repeating.  `push_start_to_absent` runs on
    EVERY score, and skips only the phones already holding an update token —
    but a phone that has just been sent a start does not register one for
    several seconds.  Every hole scored in that gap sent another start push,
    and a start push cannot see what is already on the lock screen, so each
    one raised ANOTHER card.  Four cards across two rounds, in testing.

    A row here means "asked recently, leave it alone".  It is not permanent:
    after COOLDOWN a phone with still no update token is asked again, because
    the genuine miss — a phone that was off at the tee — is exactly the case
    the retry exists for.
    """

    round      = models.ForeignKey(
                     Round, on_delete=models.CASCADE,
                     related_name='live_activity_start_pushes')
    user       = models.ForeignKey(
                     settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                     related_name='live_activity_start_pushes')
    sent_at    = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ('round', 'user')

    def __str__(self):
        return f'start push — round {self.round_id} — {self.user_id}'


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


class SettlementSend(models.Model):
    """A record that a settlement receipt actually left the app.

    Rule 8 of the receipt handoff: once sent, the receipt says
    "Texted 6:12 PM to 14 golfers", and re-opening the sheet offers Resend
    rather than pretending nothing happened — a TD who is not sure whether it
    went out will send twice.

    Kept per send rather than as a flag on the tournament, because a resend is
    a real event and the second one is the one people ask about.
    """

    MODE_FIELD    = 'field'
    MODE_PERSONAL = 'personal'
    MODE_CHOICES = [
        (MODE_FIELD,    'Field summary — one group thread'),
        (MODE_PERSONAL, 'Personal receipts — one thread each'),
    ]

    # Exactly ONE of these is set.  A tournament receipt and a casual-round
    # receipt are different documents — the first hands back money a TD held,
    # the second tells four golfers who pays whom — but "this left the app,
    # at this time, to this many people" is the same fact about both, and one
    # timeline is easier to trust than two.
    tournament = models.ForeignKey('tournament.Tournament', null=True, blank=True,
                                   on_delete=models.CASCADE,
                                   related_name='settlement_sends')
    round      = models.ForeignKey('tournament.Round', null=True, blank=True,
                                   on_delete=models.CASCADE,
                                   related_name='settlement_sends')
    mode       = models.CharField(max_length=10, choices=MODE_CHOICES)
    # WHICH golfer a personal send went to.  Null for a field summary, which
    # goes to the thread rather than to a person.  Recorded because the useful
    # question about a personal send is not "did one happen" but "have I sent
    # Ben his yet" — a per-golfer stamp cannot be derived from a count.
    player     = models.ForeignKey('core.Player', null=True, blank=True,
                                   on_delete=models.SET_NULL,
                                   related_name='settlement_sends')
    # How many golfers it went to.  The design insists a count of 14 out of 16
    # be explainable, so the number is recorded rather than re-derived later
    # from a roster that may since have changed.
    recipients = models.PositiveIntegerField(default=0)
    sent_by    = models.ForeignKey(settings.AUTH_USER_MODEL, null=True,
                                   on_delete=models.SET_NULL,
                                   related_name='settlement_sends')
    sent_at    = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-sent_at']
        constraints = [
            # A send belongs to one thing or the other, never both and never
            # neither — otherwise "the last send" has no defined answer.
            models.CheckConstraint(
                condition=(
                    models.Q(tournament__isnull=False, round__isnull=True) |
                    models.Q(tournament__isnull=True,  round__isnull=False)
                ),
                name='settlementsend_exactly_one_parent',
            ),
        ]

    def __str__(self):
        parent = f't{self.tournament_id}' if self.tournament_id else f'r{self.round_id}'
        return f'{parent} {self.mode} x{self.recipients}'
