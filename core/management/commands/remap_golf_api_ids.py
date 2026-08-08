"""
remap_golf_api_ids — stamp GolfCourseAPI's current (alphanumeric) course ids onto
catalog courses (and their account clones) that still carry the dead numeric ids.

GolfCourseAPI re-keyed courses numeric→alphanumeric, so our stored ids 404 and a
re-import would create duplicates.  This updates CatalogCourse.golf_api_id AND
every account Course sharing the old id, in one transaction.  Confirmed mapping
lives in docs/gcapi-course-ids.md.

Dry-run by default; pass --apply to write.

    python manage.py remap_golf_api_ids            # preview
    python manage.py remap_golf_api_ids --apply
"""
from django.core.management.base import BaseCommand
from django.db import transaction

# Confirmed 2026-08-08 (old numeric id -> current GCAPI slug). See docs.
REMAP = {
    '24451': '0m4sda7m',   # Chardonnay Gc
    '10423': 'qfv3y37x',   # Corica Park — North
    '26507': 'f5cnws7n',   # Corica Park — South
    '20758': 'edjn213j',   # Fairways Of Halfmoon
    '19760': 'v7g5pgyj',   # Lake Chabot Gc
    '19771': 'f19r40nr',   # Metropolitan Gl
    '19919': '1b3xwtd2',   # Monarch Bay — Tony Lema
    '19624': 'mk2sr65b',   # Paradise Valley Gc
    '19638': '4yztvh53',   # Presidio Gc
    '4753':  '7xmh8n3b',   # Red Rock CC — Arroyo
    '24539': '46xjvgxt',   # Sequoyah Cc
    '18263': '64csz6xw',   # Siena Golf Club
    '19641': 'tq7659nk',   # Tilden Park GC
}


class Command(BaseCommand):
    help = "Stamp current GCAPI ids onto catalog + account courses (see docs/gcapi-course-ids.md)."

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true',
                            help='Write the changes (default is a dry-run).')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse, Course

        apply = opts['apply']
        plan, conflicts, missing = [], [], []

        for old, new in REMAP.items():
            cc = CatalogCourse.objects.filter(golf_api_id=old).first()
            if cc is None:
                missing.append((old, new))
                self.stdout.write(self.style.WARNING(
                    f"  SKIP  {old}→{new}: no catalog course with old id"))
                continue
            clash = CatalogCourse.objects.filter(golf_api_id=new).exclude(pk=cc.pk).first()
            if clash is not None:
                conflicts.append((old, new, clash))
                self.stdout.write(self.style.ERROR(
                    f"  SKIP  {old}→{new}: new id already used by '{clash.name}' (needs merge, not remap)"))
                continue
            n_acct = Course.objects.filter(golf_api_id=old).count()
            plan.append((cc, old, new, n_acct))
            self.stdout.write(
                f"  {'REMAP' if not apply else 'REMAP…'}  {cc.name}: {old} → {new}  "
                f"(catalog + {n_acct} account course(s))")

        if apply and plan:
            with transaction.atomic():
                for cc, old, new, _ in plan:
                    cc.golf_api_id = new
                    cc.save(update_fields=['golf_api_id'])
                    Course.objects.filter(golf_api_id=old).update(golf_api_id=new)

        verb = 'Remapped' if apply else 'Would remap'
        self.stdout.write(self.style.SUCCESS(
            f"\n{verb} {len(plan)} course(s); {len(conflicts)} conflict(s), "
            f"{len(missing)} not found."))
        if not apply and plan:
            self.stdout.write('Re-run with --apply to commit.')
