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
