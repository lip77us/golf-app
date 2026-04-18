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
    email           = models.EmailField(blank=True)
    phone           = models.CharField(max_length=20, blank=True)
    handicap_index  = models.DecimalField(
                        max_digits=4, decimal_places=1,
                        validators=[MinValueValidator(-10), MaxValueValidator(54)]
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

    def hole(self, number):
        """Return the hole dict for a given hole number (1-based)."""
        return next(h for h in self.holes if h['number'] == number)

    def __str__(self):
        return f"{self.course.name} — {self.tee_name}"
