"""
seed_catalog_from_courses — backfill the shared course catalog from existing
account Courses, using their CURRENT data (so locally-modified courses are
captured exactly as you've tuned them — no GolfCourseAPI re-fetch).

    # Catalog all golf-database-imported courses across every account:
    python manage.py seed_catalog_from_courses

    # Only your account's courses (recommended so you control which modified
    # version wins), including hand-built courses that have no golf_api_id:
    python manage.py seed_catalog_from_courses --account "DemoClub" --include-custom

    # Replace catalog entries that already exist (otherwise they're left alone):
    python manage.py seed_catalog_from_courses --account "DemoClub" --overwrite

Notes:
  * Keyed by golf_api_id; courses without one get a synthetic `local-<id>` key
    and are only processed with --include-custom.
  * If several accounts share a golf_api_id, the first processed wins (use
    --account to pick yours, and/or --overwrite to let a later one replace it).
"""

from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Backfill the shared catalog from existing account Courses."

    def add_arguments(self, parser):
        parser.add_argument('--account', help='Limit to one account (name, case-insensitive).')
        parser.add_argument('--overwrite', action='store_true',
                            help='Replace catalog entries that already exist.')
        parser.add_argument('--include-custom', action='store_true',
                            help='Also catalog courses with no golf_api_id (key local-<id>).')

    def handle(self, *args, **opts):
        from core.models import Course
        from services.catalog import catalog_from_course

        qs = Course.objects.all()
        if opts.get('account'):
            qs = qs.filter(account__name__iexact=opts['account'])
        if not opts.get('include_custom'):
            qs = (qs.exclude(golf_api_id__isnull=True)
                    .exclude(golf_api_id=''))
        qs = qs.select_related('account').prefetch_related('tees')

        counts = {'created': 0, 'updated': 0, 'skipped': 0}
        for course in qs:
            _cc, status = catalog_from_course(
                course, overwrite=opts['overwrite'],
            )
            counts[status] += 1
            if status != 'skipped':
                self.stdout.write(
                    f"  {status}: {course.name} "
                    f"({course.account.name}) "
                    f"[{course.golf_api_id or f'local-{course.pk}'}]"
                )

        self.stdout.write(self.style.SUCCESS(
            f"Catalog backfill: {counts['created']} created, "
            f"{counts['updated']} updated, {counts['skipped']} skipped."
        ))
