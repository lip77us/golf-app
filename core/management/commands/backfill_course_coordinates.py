"""
backfill_course_coordinates — give older courses the point they were imported
without.

Courses imported before the API adapter kept `latitude`/`longitude` have none,
which makes "start on the course you are standing at" (`mobile/lib/utils/
default_course.dart`) and Near you silently skip them. Locally that was 5 of 70
account courses and 4 of 24 catalog rows — including the home course.

    python manage.py backfill_course_coordinates            # dry run
    python manage.py backfill_course_coordinates --apply    # write them
    python manage.py backfill_course_coordinates --apply --limit 25

One GolfCourseAPI call per DISTINCT `golf_api_id`, however many account copies
share it, and each answer fills every `Course` and `CatalogCourse` row with
that id that has no point yet. It only ever fills a NULL: a course that already
has coordinates, or was corrected by hand, is never touched. Courses with no
`golf_api_id` (hand-built or pasted) have nothing to look up and are left alone.

Dry run by default, like the other importers here. The calls count against the
upstream daily allowance, so `--limit` exists.
"""
from django.core.management.base import BaseCommand


def _usable(lat, lon):
    """A real point: both present, numeric, and not the (0, 0) of a missing
    geocode."""
    try:
        la, lo = float(lat), float(lon)
    except (TypeError, ValueError):
        return None
    if la == 0 and lo == 0:
        return None
    if not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None
    return round(la, 6), round(lo, 6)


class Command(BaseCommand):
    help = "Fill missing course coordinates from GolfCourseAPI (dry run by default)."

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true',
                            help='Write the coordinates (default is a dry run).')
        parser.add_argument('--limit', type=int, default=0,
                            help='Look up at most this many distinct courses.')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse, Course
        from services.golf_api_client import fetch_course

        ids = set(Course.objects.filter(latitude__isnull=True)
                  .exclude(golf_api_id__isnull=True).exclude(golf_api_id='')
                  .values_list('golf_api_id', flat=True))
        ids |= set(CatalogCourse.objects.filter(latitude__isnull=True)
                   .exclude(golf_api_id='')
                   .values_list('golf_api_id', flat=True))
        # `local-`, `manual-` and `seed-` are ids WE made up (pasted courses,
        # the demo seed); upstream has never heard of them.
        ids = sorted(i for i in ids
                     if not str(i).startswith(('local-', 'manual-', 'seed-')))
        if opts['limit']:
            ids = ids[:opts['limit']]

        found = missed = failed = rows = 0
        for api_id in ids:
            try:
                data = fetch_course(api_id)
            except Exception as e:  # one bad id never stops the rest
                failed += 1
                self.stderr.write(f'  {api_id}: lookup failed ({type(e).__name__})')
                continue
            point = _usable(data.get('latitude'), data.get('longitude'))
            if point is None:
                missed += 1
                self.stdout.write(f'  {api_id}: no coordinates upstream')
                continue
            found += 1
            n = (Course.objects.filter(golf_api_id=api_id, latitude__isnull=True).count()
                 + CatalogCourse.objects.filter(golf_api_id=api_id,
                                                latitude__isnull=True).count())
            rows += n
            self.stdout.write(f'  {api_id}: {point[0]}, {point[1]}  ({n} rows)')
            if opts['apply']:
                Course.objects.filter(golf_api_id=api_id, latitude__isnull=True) \
                    .update(latitude=point[0], longitude=point[1])
                CatalogCourse.objects.filter(golf_api_id=api_id, latitude__isnull=True) \
                    .update(latitude=point[0], longitude=point[1])

        verb = 'Updated' if opts['apply'] else 'Would update'
        self.stdout.write(self.style.SUCCESS(
            f'{verb} {rows} rows from {found} courses; '
            f'{missed} had no point upstream, {failed} lookups failed.'
            + ('' if opts['apply'] else '  (dry run — pass --apply)')))
