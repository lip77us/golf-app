"""
console/models.py
-----------------
Persistence for the TD console.

Today that is one model: ``ImportRun``, the record of a Golf Genius roster
import.  The CLI (``manage.py import_genius_roster``) leaves no trace — it
prints a diff and either writes or doesn't.  The console keeps the run,
because two things depend on it:

* **The preview has to survive a round trip.**  A TD who types an index into a
  skipped row re-posts the page, and the plan is rebuilt from the *parsed rows
  plus the overrides* rather than from a re-upload.  So the parsed file lives
  here between the drop and the apply.

* **Every write leaves a record.**  The receipt is a page you can come back to,
  runs are numbered per account, and the applied change log is stored per row —
  which is also everything a future per-run reversal would need.  (There is no
  undo today; the importer has none.  See docs.)
"""

from django.conf import settings
from django.db import models


class ImportRun(models.Model):
    """One pass of the Golf Genius importer, from file drop to receipt.

    A run is created the moment a file parses, in ``preview`` status, and
    writes nothing.  ``apply()`` in services/genius_import commits it and the
    view flips it to ``applied`` with a per-account run number.  A run the TD
    walks away from stays ``preview`` forever and is never numbered — the
    numbers in "Recent runs" are the imports that actually happened.
    """

    STATUS_PREVIEW   = 'preview'
    STATUS_APPLIED   = 'applied'
    STATUS_DISCARDED = 'discarded'
    STATUS_CHOICES = [
        (STATUS_PREVIEW,   'Preview'),
        (STATUS_APPLIED,   'Applied'),
        (STATUS_DISCARDED, 'Discarded'),
    ]

    account     = models.ForeignKey('accounts.Account', on_delete=models.CASCADE,
                                    related_name='import_runs')
    user        = models.ForeignKey(settings.AUTH_USER_MODEL, null=True,
                                    on_delete=models.SET_NULL,
                                    related_name='import_runs',
                                    help_text='Who dropped the file.')
    status      = models.CharField(max_length=10, choices=STATUS_CHOICES,
                                   default=STATUS_PREVIEW)
    # Per-account, 1-based, assigned on apply.  NULL while the run is a preview
    # so an abandoned draft never burns a number.
    number      = models.PositiveIntegerField(null=True, blank=True)

    filename    = models.CharField(max_length=255)
    file_size   = models.PositiveIntegerField(default=0)
    # What the header scan found.  Golf Genius prefixes a title banner, so the
    # importer hunts for the row carrying First Name / Last Name — and the
    # failure mode is silent: point it at the wrong sheet and the only symptom
    # is a plausible-looking small number.  So the console states it.
    header_line = models.PositiveIntegerField(default=0)
    data_rows   = models.PositiveIntegerField(default=0)
    roster_size = models.PositiveIntegerField(
                    default=0,
                    help_text='Golfers already in the account when the file was read.')

    # The parsed file — one dict per data row (see console/plan.py).  The plan
    # is a pure function of this plus `overrides`, so the preview is rebuildable
    # without asking the TD to drop the file again.
    parsed      = models.JSONField(default=list)
    # {source line number (str) -> index the TD typed}.  The console's one
    # addition to the importer: "new golfer has no index" is the common skip and
    # the only one fixable without a round trip to Golf Genius.
    overrides   = models.JSONField(default=dict, blank=True)

    # Filled on apply: counts, plus a per-row log of what was written.
    result      = models.JSONField(default=dict, blank=True)

    created_at  = models.DateTimeField(auto_now_add=True)
    applied_at  = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ['-created_at']
        constraints = [
            models.UniqueConstraint(
                fields=['account', 'number'],
                condition=models.Q(number__isnull=False),
                name='console_importrun_account_number_unique',
            ),
        ]

    def __str__(self):
        label = f'#{self.number}' if self.number else 'draft'
        return f'{self.account_id} import {label} — {self.filename}'

    def next_number(self) -> int:
        """The next per-account run number.  Called inside apply()'s
        transaction, so two concurrent applies collide on the unique
        constraint rather than silently sharing a number."""
        highest = (ImportRun.objects
                   .filter(account=self.account, number__isnull=False)
                   .aggregate(models.Max('number'))['number__max'])
        return (highest or 0) + 1


class CourseCheck(models.Model):
    """A record that somebody looked at a course record and what came of it.

    Three things can happen when a TD holds the printed card next to our data,
    and all three are worth keeping:

    * ``verified`` — nothing was wrong.  This is the one people forget to
      record, and it is the only way a course record earns the difference
      between *right* and *never looked at*.  Without it the library cannot
      tell a checked course from an unchecked one.
    * ``edited``   — the account's own copy was corrected.  Local and
      immediate; the account owns its clone.
    * ``reported`` — the correction was pushed at the SHARED catalog, which
      every other account clones from.  Staff write straight through;
      everyone else files it and it is actioned elsewhere.

    Keeping all three in one table is deliberate: the library's state is
    "whatever happened to this course most recently", and that question has one
    answer only if there is one timeline.
    """

    KIND_VERIFIED = 'verified'
    KIND_EDITED   = 'edited'
    KIND_REPORTED = 'reported'
    KIND_CHOICES = [
        (KIND_VERIFIED, 'Checked, nothing wrong'),
        (KIND_EDITED,   'Record corrected'),
        (KIND_REPORTED, 'Sent to Halved'),
    ]

    # Where the TD's information came from.  Whoever fixes the shared record
    # needs to know whether they are looking at a re-rating or a typo, and
    # these three answers sort the queue on their own.
    SOURCE_CARD  = 'scorecard'
    SOURCE_GHIN  = 'ghin'
    SOURCE_CLUB  = 'club'
    SOURCE_CHOICES = [
        (SOURCE_CARD, 'The printed scorecard'),
        (SOURCE_GHIN, 'GHIN'),
        (SOURCE_CLUB, 'The club told me'),
    ]

    STATUS_SENT     = 'sent'
    STATUS_REVIEW   = 'in_review'
    STATUS_APPLIED  = 'applied'
    STATUS_CHOICES = [
        (STATUS_SENT,    'Sent'),
        (STATUS_REVIEW,  'In review'),
        (STATUS_APPLIED, 'Applied upstream'),
    ]

    account    = models.ForeignKey('accounts.Account', on_delete=models.CASCADE,
                                   related_name='course_checks')
    course     = models.ForeignKey('core.Course', on_delete=models.CASCADE,
                                   related_name='checks')
    user       = models.ForeignKey(settings.AUTH_USER_MODEL, null=True,
                                   on_delete=models.SET_NULL,
                                   related_name='course_checks')
    kind       = models.CharField(max_length=10, choices=KIND_CHOICES)
    # Per-account and 1-based, like an import run — a course report a TD can
    # refer to by number is one they can follow up on.
    number     = models.PositiveIntegerField(null=True, blank=True)

    # Which tee this concerned, when it concerned one.  Kept as a plain label
    # rather than an FK: an edit SUPERSEDES the Tee row it changed (see
    # services/tee_revisions), so an FK here would point at a retired revision
    # and read as though the check applied to something no longer current.
    tee_name   = models.CharField(max_length=50, blank=True)

    # Field-level before/after, the same shape the import receipt uses:
    # [{'label': 'hole 5 index', 'before': '5', 'after': '12'}, ...]
    changes    = models.JSONField(default=list, blank=True)

    source     = models.CharField(max_length=10, choices=SOURCE_CHOICES, blank=True)
    note       = models.TextField(blank=True)
    status     = models.CharField(max_length=10, choices=STATUS_CHOICES, blank=True)
    # True when this actually wrote to the shared CatalogCourse rather than
    # only asking someone to.
    upstream   = models.BooleanField(default=False)

    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']
        constraints = [
            models.UniqueConstraint(
                fields=['account', 'number'],
                condition=models.Q(number__isnull=False),
                name='console_coursecheck_account_number_unique',
            ),
        ]

    def __str__(self):
        return f'{self.course_id} {self.kind} #{self.number or "-"}'

    def next_number(self) -> int:
        highest = (CourseCheck.objects
                   .filter(account=self.account, number__isnull=False)
                   .aggregate(models.Max('number'))['number__max'])
        return (highest or 0) + 1
