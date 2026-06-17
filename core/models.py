from django.conf import settings
from django.db import models
from django.core.validators import MinValueValidator, MaxValueValidator

from accounts.scoping import AccountScopedManager


# ---------------------------------------------------------------------------
# ENUMS / CHOICES
# ---------------------------------------------------------------------------

class GameType(models.TextChoices):
    IRISH_RUMBLE    = 'irish_rumble',    'Irish Rumble'
    NASSAU          = 'nassau',          'Nassau'
    SIXES           = 'sixes',           'Sixes'
    PINK_BALL       = 'pink_ball',       'Pink Ball'
    SCRAMBLE        = 'scramble',        'Scramble'
    STABLEFORD      = 'stableford',      'Stableford'
    SKINS           = 'skins',           'Skins'
    # Multi-Foursome Skins: round-level skins pool across every participating
    # foursome.  Players opt in individually (roster is explicit, not the
    # union of foursome rosters).  Lowest score on a hole wins 1 skin;
    # ties kill the skin (no carryover, no junk).  Mutually exclusive with
    # any other multi-foursome game, but compatible with per-foursome side
    # games (sixes, points-531, single-foursome skins, etc.) running
    # simultaneously inside each group.
    MULTI_SKINS     = 'multi_skins',     'Multi-Group Skins'
    LOW_NET_ROUND   = 'low_net_round',   'Low Net (Round)'
    LOW_NET         = 'low_net',         'Low Net Championship'
    # Points 5-3-1: a 3-player, per-hole points game.  Per-hole rank awards
    # 5/3/1 points with tie-splitting (so each hole always pays out 9
    # points total).  Settles against a "par" of 3 points per hole: a
    # 55-point player over 18 holes wins 1 bet_unit.  Because the sum of
    # points on every hole is 3 × 3 = 9, the money sums to zero across
    # the three players.  The casual-round UI restricts this game to
    # foursomes with exactly three real players and is mutually
    # exclusive with Sixes.
    POINTS_531      = 'points_531',      'Points 5-3-1'
    # Three-Person Match: tournament game for a 3-player group.  Phase 1
    # (holes 1–9) uses Points 5-3-1 to seed the players; phase 2 (holes
    # 10–18) is 1v1 match play between the top two finishers.  Tie-breaking
    # rules handle 3-way ties (continue 5-3-1) and 2nd/3rd-place ties
    # (concurrent sub-match + 1st plays best ball simultaneously).
    THREE_PERSON_MATCH = 'three_person_match', 'Three-Person Match'
    # Match Play: single-elimination bracket for a 4-player foursome.
    # Holes 1–9 host two semi-finals (player1 vs player2, player3 vs
    # player4).  Holes 10–18 host the Final (winners) plus a 3rd-place
    # consolation match (losers).  Bracket structure + per-hole match-up
    # net comparison live in services/match_play.py and
    # games/models.py MatchPlayBracket/Match/HoleResult.  Used as a
    # casual single-foursome game and as a tournament per-foursome side
    # game alongside Stroke Play.
    MATCH_PLAY      = 'match_play',      'Match Play'
    # Quota Nassau: two-player Stableford-vs-quota comparison, Nassau style.
    # Quota = 36 − course_handicap_index. Compare score-vs-quota at F9/B9/18.
    # Used as the per-foursome game type in Ryder Cup rounds.
    QUOTA_NASSAU    = 'quota_nassau',    'Quota Nassau'
    # Singles Nassau: two 1v1 Nassau matches per foursome (F9/B9/Overall each).
    # Uses MatchPlayBracket for score tracking.
    # Cup multiplier: pv × 6 per foursome (2 matches × 3 segments).
    SINGLES_NASSAU  = 'singles_nassau',  'Singles Nassau'
    # 18-Hole Singles: two 1v1 stroke/match-play singles per foursome,
    # 18-hole overall result only — no F9/B9 breakdown.
    # Cup multiplier: pv × 2 per foursome (2 matches × 1 point each).
    SINGLES_18      = 'singles_18',      '18-Hole Singles'
    # One-Round Ryder Cup ("Triple Cup"): a foursome plays one 18-hole
    # match split into three 6-hole segments — Fourball (best-ball),
    # Foursomes (alt-shot), and Singles.  In the canonical 2v2 the
    # singles segment is two simultaneous 1v1 matches, yielding 4
    # matches per foursome.  Works as both a cup game (slots into
    # RyderCupFoursomeConfig) and a casual game for 2-4 players.
    # Cup multiplier: pv × 4 per foursome (2v2 case).
    TRIPLE_CUP      = 'triple_cup',      'One-Round Triple Cup'
    # Wolf: a 3- or 4-player casual game.  On each hole one player is the
    # "Wolf" (a rotation the group sets, like Pink Ball's carrier order),
    # who tees last and then either takes a partner (4-player only → 2v2),
    # goes Lone Wolf (1-vs-rest, higher stake), or Blind Wolf (declared
    # pre-tee, highest stake).  Best ball per side decides the hole.  Points
    # are a zero-based system: the winning side splits a per-hole pot and
    # the losing side splits its negative, so every scored hole nets to
    # zero.  Point values (lone / blind / team-win) and a couple of options
    # (wolf-loses-ties, non-wolf clean-win bonus) are configurable.  In a
    # 4-player game, holes 17–18 hand the Wolf to whoever is in last place.
    WOLF            = 'wolf',            'Wolf'
    # Rabbit: a 3-player game.  The first to win a hole outright "catches"
    # the rabbit and runs ahead; they hold it until an opponent beats them
    # on a hole, which frees it (up for grabs again).  In accumulate mode
    # the holder builds a lead (+1 per hole won, −1 per hole lost) and only
    # loses the rabbit when the lead hits 0; in stop mode the first loss
    # frees it.  Played as 1×18, 2×9, or 3×6 segments — whoever holds the
    # rabbit at the end of a segment wins that share of the pot.
    RABBIT          = 'rabbit',          'Rabbit'
    # Las Vegas: a 2v2 game.  Each team forms a 2-digit number from its two
    # net scores (low = tens, high = ones, each digit capped at 9); the lower
    # number wins the hole and scores the difference.  A gross birdie either
    # flips the opponents' digits or multiplies the points (per setup), and
    # tied holes can carry.
    VEGAS           = 'vegas',           'Las Vegas'


class RoundStatus(models.TextChoices):
    PENDING     = 'pending',    'Pending'
    IN_PROGRESS = 'in_progress','In Progress'
    COMPLETE    = 'complete',   'Complete'


class MatchStatus(models.TextChoices):
    PENDING     = 'pending',    'Pending'
    IN_PROGRESS = 'in_progress','In Progress'
    COMPLETE    = 'complete',   'Complete'
    HALVED      = 'halved',     'Halved'


class TeamSelectMethod(models.TextChoices):
    LONG_DRIVE    = 'long_drive',    'Long Drive'
    RANDOM        = 'random',        'Random'
    REMAINDER     = 'remainder',     'Remainder'
    LOSER_CHOICE  = 'loser_choice',  "Loser's Choice"


class PlayerSex(models.TextChoices):
    """
    Designation used to pick the appropriate tee (most courses have
    separate men's and women's tees: e.g. 'White' for men, 'Red W' for
    women).  We're matching the course's own tee designations, not
    making any claim about the player beyond which tee they play.
    """
    MALE   = 'M', 'Male'
    FEMALE = 'W', 'Female'


class HandicapMode(models.TextChoices):
    """
    How per-hole scores are adjusted for handicap in a game.

    NET    — each player's playing handicap (optionally scaled by net_percent)
             is allocated by hole stroke index; net_score = gross - strokes.
    GROSS  — no strokes given; raw gross scores are used.
    STROKES_OFF — reserved for a future mode where the low-handicap player
                  plays to 0 and everyone else gets (own HCP - low HCP)
                  strokes allocated by hole index.
    """
    NET          = 'net',          'Net'
    GROSS        = 'gross',        'Gross'
    STROKES_OFF  = 'strokes_off',  'Strokes Off Low'


# ---------------------------------------------------------------------------
# CORE MODELS
# ---------------------------------------------------------------------------

class Player(models.Model):
    """
    A real golfer. handicap_index is the WHS index (e.g. 14.2).
    Course handicap is calculated per-round per-tee using:
        CH = round( handicap_index × (slope / 113) + (course_rating - par) )
    is_phantom flags ghost players created to pad 3-somes to 4.

    `account` is the tenant boundary — every Player lives inside exactly
    one Account.  The phantom (is_phantom=True) singleton is shared
    across accounts via a per-account row; we keep one phantom per
    account so scoring code that filters by `account` continues to
    find a phantom player without leaking across tenants.
    """
    account         = models.ForeignKey(
                        'accounts.Account',
                        on_delete=models.CASCADE,
                        related_name='players',
                        help_text="Tenant this player belongs to.",
                    )
    user            = models.OneToOneField(
                        settings.AUTH_USER_MODEL,
                        on_delete=models.SET_NULL,
                        null=True, blank=True,
                        related_name='player_profile',
                        help_text="Linked Django user account for API token auth."
                    )
    name            = models.CharField(max_length=100)
    # Short, compact label used wherever the UI would otherwise compute
    # initials (e.g. Sixes team abbreviations).  Up to 5 characters.
    # When left blank on save() we auto-fill from the player's name using
    # the initials-of-first-two-words convention so existing screens keep
    # their current look with zero extra data entry.  Callers may override
    # at any time via the admin or the player form.
    short_name      = models.CharField(
                        max_length=5, blank=True,
                        help_text="Short display label (max 5 chars). "
                                  "Auto-defaults to initials of first two "
                                  "name words when left blank.",
                    )
    email           = models.EmailField(blank=True)
    phone           = models.CharField(max_length=20, blank=True)
    handicap_index  = models.DecimalField(
                        max_digits=4, decimal_places=1,
                        validators=[MinValueValidator(-10), MaxValueValidator(54)]
                    )
    # Drives which tee the player gets by default during round setup.
    # Tees are filtered by this (plus any unisex tees) and then sorted
    # by Tee.sort_priority, so a course with multiple matching tees
    # (e.g. Black-M / Blue-M / White-M) can still surface the right
    # default rather than sorting alphabetically.  Nullable would be
    # nice for privacy but the tee picker needs a value, so default M.
    sex             = models.CharField(
                        max_length=1,
                        choices=PlayerSex.choices,
                        default=PlayerSex.MALE,
                        help_text="Determines the default tee during round setup.",
                    )
    is_phantom      = models.BooleanField(default=False)
    created_at      = models.DateTimeField(auto_now_add=True)

    objects         = AccountScopedManager()

    def effective_handicap_index(self):
        """The authoritative WHS index to use for this golfer.

        For a golfer who's "On Halved" — their phone matches a registered user
        who maintains their OWN profile — return THAT profile's index so a
        friend's copy follows the golfer's self-maintained handicap. Otherwise
        (login-less guests, or no match) fall back to the locally-stored value.
        """
        if not self.phone:
            return self.handicap_index
        from accounts.phone import normalize
        from django.contrib.auth import get_user_model
        n = normalize(self.phone)
        if not n:
            return self.handicap_index
        u = (get_user_model().objects.filter(phone=n)
             .select_related('player_profile').first())
        if u is not None:
            prof = getattr(u, 'player_profile', None)
            # prof.id != self.id guards the golfer's own profile (no self-loop).
            # A 0/unset owner index means "not provided yet" — fall back to the
            # locally-typed value rather than overriding it with a default 0.
            if prof is not None and prof.id != self.id and prof.handicap_index != 0:
                return prof.handicap_index
        return self.handicap_index

    def course_handicap(self, tee):
        """
        Calculate course handicap for a given Tee.
        Returns an integer per WHS rules. Uses the golfer's authoritative index
        (see effective_handicap_index) so a connected golfer's self-maintained
        handicap is what gets applied at round setup.
        """
        ch = float(self.effective_handicap_index()) * (float(tee.slope) / 113.0) + (float(tee.course_rating) - float(tee.par))
        return round(ch)

    @staticmethod
    def default_short_name_for(name: str) -> str:
        """
        Compute the default short_name for a player with the given full name.
        Takes the first letter of each of the first two whitespace-separated
        words, uppercased.  Clamped to 5 characters to match the field
        max_length.  Exposed as a staticmethod so the mobile form can
        pre-compute the same default before the row is saved.
        """
        parts = (name or '').strip().split()
        initials = ''.join(p[0].upper() for p in parts[:2] if p)
        return initials[:5]

    def save(self, *args, **kwargs):
        # Auto-fill short_name from initials when left blank so existing
        # callers and fixtures don't need updating and existing UI that
        # shows initials keeps working seamlessly.
        if not self.short_name:
            self.short_name = self.default_short_name_for(self.name)
        super().save(*args, **kwargs)

    def __str__(self):
        suffix = ' (phantom)' if self.is_phantom else ''
        return f"{self.name}{suffix}"


class Course(models.Model):
    """
    A golf course that has multiple tees.

    `account` is the tenant boundary — courses are per-account so each
    group maintains its own catalog (their actual home courses, plus
    any custom layouts).  Two accounts may both have a "Pebble Beach"
    row with independent edits and tee configurations.
    """
    account         = models.ForeignKey(
                        'accounts.Account',
                        on_delete=models.CASCADE,
                        related_name='courses',
                        help_text="Tenant this course belongs to.",
                    )
    name            = models.CharField(max_length=150)
    # Provenance: the GolfCourseAPI course id this row was imported from, if
    # any (NULL for manually pasted / created courses).  Courses are still
    # OWNED per-account, so this is intentionally NOT unique — the same
    # real-world course imported into N accounts yields N rows sharing this
    # id.  Persisted from the first self-signup onward so we can recognize
    # "the same course" across accounts later (e.g. to dedupe imports or
    # migrate to a shared course catalog) without a costly backfill.
    golf_api_id     = models.CharField(
                        max_length=64, null=True, blank=True, db_index=True,
                        help_text="Source GolfCourseAPI course id when imported "
                                  "from there; NULL for manual courses.",
                    )
    # Location (from the course database) — used to display and disambiguate
    # courses (e.g. "Lincoln Park — Chicago, IL") and to power name/city search.
    # Carried onto the account copy when cloned from the shared catalog.
    city            = models.CharField(max_length=80, blank=True)
    state           = models.CharField(max_length=80, blank=True)
    country         = models.CharField(max_length=80, blank=True)
    latitude        = models.DecimalField(max_digits=9, decimal_places=6,
                                          null=True, blank=True)
    longitude       = models.DecimalField(max_digits=9, decimal_places=6,
                                          null=True, blank=True)
    created_at      = models.DateTimeField(auto_now_add=True)

    objects         = AccountScopedManager()

    def __str__(self):
        return self.name


class Tee(models.Model):
    """
    One tee set at one course. holes is a list of 18 dicts:
        [{ "number": 1, "par": 4, "stroke_index": 7, "yards": 412 }, ...]
    stroke_index (1–18) is used to allocate handicap strokes per hole.
    """
    course          = models.ForeignKey(Course, on_delete=models.CASCADE, related_name='tees')
    tee_name        = models.CharField(max_length=50)   # e.g. "White", "Blue"
    slope           = models.PositiveSmallIntegerField(
                        validators=[MinValueValidator(55), MaxValueValidator(155)]
                    )
    course_rating   = models.DecimalField(max_digits=4, decimal_places=1)
    par             = models.PositiveSmallIntegerField(default=72)
    holes           = models.JSONField()                # list of 18 hole dicts (see above)
    # Which sex this tee is intended for.  Null = unisex (e.g. Black /
    # Championship tees played from by low-handicap players of either
    # sex).  Used alongside Player.sex to narrow the tee picker default.
    sex             = models.CharField(
                        max_length=1,
                        choices=PlayerSex.choices,
                        null=True, blank=True,
                        help_text="Tee designation. Null for unisex.",
                    )
    # Lower number = more commonly-used tee.  When multiple tees match
    # the player's sex, the lowest sort_priority is the default.
    # Example ordering for a men's side: Black=10, Blue=20, White=30.
    # Women's side: Red W=30.  Unisex Black could be 10 for both.
    sort_priority   = models.PositiveSmallIntegerField(
                        default=100,
                        help_text="Lower = more default. Used to pick the "
                                  "default tee for a player of a given sex.",
                    )

    def hole(self, number):
        """Return the hole dict for a given hole number (1-based)."""
        return next(h for h in self.holes if h['number'] == number)

    def __str__(self):
        return f"{self.course.name} — {self.tee_name}"


class CatalogCourse(models.Model):
    """
    A course in the shared, deduped catalog — the canonical source that any
    account can pull from.  Populated automatically whenever someone imports a
    course from the GolfCourseAPI (keyed by golf_api_id, so the same real-world
    course is stored once network-wide).  NOT tenant-scoped (no `account`).

    Accounts don't reference catalog rows directly: "adding" a catalog course
    CLONES it into the account's own Course/Tee rows (see services/catalog.py /
    CourseImportView), so each account keeps local edits — above all
    Tee.sort_priority.  Hand-typed (pasted) courses never enter the catalog.
    """
    golf_api_id     = models.CharField(max_length=64, unique=True, db_index=True)
    name            = models.CharField(max_length=150)
    city            = models.CharField(max_length=80, blank=True)
    state           = models.CharField(max_length=80, blank=True)
    country         = models.CharField(max_length=80, blank=True)
    latitude        = models.DecimalField(max_digits=9, decimal_places=6,
                                          null=True, blank=True)
    longitude       = models.DecimalField(max_digits=9, decimal_places=6,
                                          null=True, blank=True)
    created_at      = models.DateTimeField(auto_now_add=True)
    updated_at      = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['name']

    def __str__(self):
        loc = ', '.join(p for p in (self.city, self.state) if p)
        return f"{self.name}{f' — {loc}' if loc else ''}"


class CatalogTee(models.Model):
    """One tee set on a CatalogCourse — mirrors Tee so a clone is a
    field-for-field copy.  `default_sort_priority` seeds the cloned
    Tee.sort_priority, which the owning account may then change locally."""
    catalog_course        = models.ForeignKey(
                                CatalogCourse, on_delete=models.CASCADE,
                                related_name='tees',
                            )
    tee_name              = models.CharField(max_length=50)
    slope                 = models.PositiveSmallIntegerField(
                                validators=[MinValueValidator(55), MaxValueValidator(155)]
                            )
    course_rating         = models.DecimalField(max_digits=4, decimal_places=1)
    par                   = models.PositiveSmallIntegerField(default=72)
    holes                 = models.JSONField()
    sex                   = models.CharField(
                                max_length=1, choices=PlayerSex.choices,
                                null=True, blank=True,
                            )
    default_sort_priority = models.PositiveSmallIntegerField(default=100)

    def __str__(self):
        return f"{self.catalog_course.name} — {self.tee_name}"
