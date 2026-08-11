"""
fix_prod_catalog — one-shot, IDEMPOTENT reconciliation of the shared catalog to
GolfCourseAPI, packaging the vetted 2026-08-08 sequence (docs/gcapi-course-ids.md)
into a single reviewable command so it can be run safely against prod:

  1. remap dead numeric golf_api_ids -> current alphanumeric slugs
  2. per course: un-curate standard tees, re-import from GCAPI, propagate to clones
  3. rename dedups: drop the leftover old-named tees GCAPI renamed
     (YELLOW-W -> Yellow, B/W Combo -> Blue/White Combo, Blue -> Black)

Dry-run by DEFAULT: the whole pipeline runs inside one transaction and is rolled
back at the end, so you get a true preview (later steps see earlier steps'
effects) with zero writes. `--apply` commits. All-or-nothing: any error rolls the
whole thing back, so prod never ends up half-migrated.

Idempotent: re-running is safe — remap skips already-migrated ids, un-curate finds
nothing to flip, re-import is a no-op when GCAPI is unchanged, dedups find nothing.

    # in the Railway "Golf App" service Terminal:
    /opt/venv/bin/python manage.py fix_prod_catalog            # dry-run (rolls back)
    /opt/venv/bin/python manage.py fix_prod_catalog --apply

Run during low traffic — it holds a transaction across the GCAPI fetches.
"""
import time

from django.core.management import call_command
from django.core.management.base import BaseCommand
from django.db import transaction

# (slug, include_combos).  Tilden is the ONLY course excluded from --include-combos
# so its curated White-Sixes tee is protected (un-curating it would let the
# re-import delete it).
COURSES = [
    ('tq7659nk', False),  # Tilden Park GC
    ('1b3xwtd2', True),   # Monarch Bay — Tony Lema
    ('f5cnws7n', True),   # Corica Park — South
    ('0m4sda7m', True),   # Chardonnay Gc
    ('7xmh8n3b', True),   # Red Rock — Arroyo
    ('f19r40nr', True),   # Metropolitan Gl
    ('qfv3y37x', True),   # Corica Park — North
    ('edjn213j', True),   # Fairways of Halfmoon
]

# (slug, old_tee_name, sex) — tees GCAPI renamed; delete the leftover old-named
# copies so no duplicate remains. Catalog copies deleted outright (no PROTECT);
# account copies deleted only when UNREFERENCED (a played tee stays, harmless).
RENAME_DEDUPES = [
    ('tq7659nk', 'YELLOW-W', 'W'),    # -> GCAPI 'Yellow (W)'
    ('f19r40nr', 'B/W Combo', 'M'),   # -> 'Blue/White Combo'
    ('f19r40nr', 'B/W Combo', 'W'),
    ('edjn213j', 'Blue', 'M'),        # -> 'Black (M)'
]


class _DryRunRollback(Exception):
    pass


class Command(BaseCommand):
    help = "Idempotently reconcile the catalog to GCAPI (remap + reimport + dedup)."

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true',
                            help='Commit the changes (default is a dry-run that rolls back).')
        parser.add_argument('--sleep', type=float, default=4.0,
                            help='Seconds between per-course GCAPI fetches (rate-limit spacing).')

    def handle(self, *args, **opts):
        apply = opts['apply']
        banner = 'APPLY' if apply else 'DRY-RUN (rolls back at the end)'
        self.stdout.write(self.style.MIGRATE_HEADING(f'\n=== fix_prod_catalog — {banner} ===\n'))
        try:
            with transaction.atomic():
                self._run(opts['sleep'])
                if not apply:
                    raise _DryRunRollback
        except _DryRunRollback:
            self.stdout.write(self.style.WARNING(
                '\nDRY-RUN complete — ALL changes rolled back. Re-run with --apply to commit.'))
            return
        self.stdout.write(self.style.SUCCESS('\nfix_prod_catalog applied successfully.'))

    def _run(self, sleep):
        from core.models import CatalogTee, Tee

        # 1) Remap dead numeric ids -> current slugs.
        self.stdout.write('--- 1. remap ids ---')
        call_command('remap_golf_api_ids', apply=True)

        # 2) Per course: un-curate + re-import + propagate.
        for i, (gid, combos) in enumerate(COURSES):
            if i:
                time.sleep(sleep)
            self.stdout.write(f'\n--- 2. {gid}: uncurate + reimport ---')
            call_command('uncurate_catalog_tees',
                         golf_api_id=gid, apply=True, include_combos=combos)
            call_command('reimport_catalog_course',
                         golf_api_id=gid, propagate=True, apply=True)

        # 3) Rename dedups — drop leftover old-named tees.
        self.stdout.write('\n--- 3. rename dedups ---')
        for gid, name, sex in RENAME_DEDUPES:
            cat_del = CatalogTee.objects.filter(
                catalog_course__golf_api_id=gid, tee_name=name, sex=sex).delete()[0]
            acct_del = acct_kept = 0
            for t in Tee.objects.filter(course__golf_api_id=gid, tee_name=name, sex=sex):
                if Tee.objects.filter(pk=t.pk, memberships__isnull=False).exists():
                    acct_kept += 1
                else:
                    t.delete()
                    acct_del += 1
            self.stdout.write(
                f'  {name} ({sex}) @ {gid}: catalog -{cat_del}, account -{acct_del} '
                f'(kept {acct_kept} referenced)')
