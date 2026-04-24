from django.conf import settings
from django.db import models
from django.core.validators import MinValueValidator, MaxValueValidator


# ---------------------------------------------------------------------------
# ENUMS / CHOICES
# ---------------------------------------------------------------------------

class GameType(models.TextChoices):
    IRISH_RUMBLE    = 'irish_rumble',    'Irish Rumble'
    NASSAU          = 'nassau',          'Nassau'
    SIXES           = 'sixes',           "Six's"
    PINK_BALL       = 'pink_ball',       'Pink Ball'
    SCRAMBLE        = 'scramble',        'Scramble'
    MATCH_PLAY      = 'match_play',      'Match Play'
    STABLEFORD      = 'stableford',      'Stableford'
    SKINS           = 'skins',           'Skins'
    LOW_NET_ROUND   = 'low_net_round',   'Low Net (Round)'
    LOW_NET         = 'low_net',         'Low Net Championship'
    # Points 5-3-1: a 3-player, per-hole points game.  Per-hole rank awards
    # 5/3/1 points with tie-splitting (so each hole always pays out 9
    # points total).  Settles against a "par" of 3 points per hole: a
    # 55-point player over 18 holes wins 1 bet_unit.  Because the sum of
    # points on every hole is 3 × 3 = 9, the money sums to zero across
    # the three players.  The casual-round UI restricts this game to
    # foursomes with exactly three real players and is mutually
    # exclusive with Six's.
    POINTS_531      = 'points_531',      'Points 5-3-1'


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
    """
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

    def course_handicap(self, tee):
        """
        Calculate course handicap for a given Tee.
        Returns an integer per WHS rules.
        """
        ch = float(self.handicap_index) * (float(tee.slope) / 113.0) + (float(tee.course_rating) - float(tee.par))
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
    """
    name            = models.CharField(max_length=150)
    created_at      = models.DateTimeField(auto_now_add=True)

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
