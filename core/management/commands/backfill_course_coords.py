"""Re-fetch latitude/longitude for courses that were imported before the
adapter kept them.

`services/golf_api_client._adapt_course_detail` keeps lat/lng now, but every
course imported before that change has none — and the homepage map plots one
dot per course, so a missing pair is a course that silently is not there.

**Only courses with a `golf_api_id` can be fixed.** A pasted course was never
fetched from anywhere and has no id to re-fetch by; it is reported and left
alone. Geocoding by name is deliberately NOT done here — inventing a
coordinate for a course somebody typed by hand puts a dot on a map that
nobody can check, and the map's whole claim is that it shows where rounds
were really played.

Dry-run by default, like every other write command in this repo. `--apply`
commits.

    python manage.py backfill_course_coords            # preview
    python manage.py backfill_course_coords --apply
"""
from decimal import Decimal, InvalidOperation

from django.core.management.base import BaseCommand
from django.db import transaction

from core.models import CatalogCourse, Course
from scoring.models import HoleScore
from tournament.models import Round


def _coord(value, limit):
    """One coordinate, or None if it is not a usable number.

    `limit` must be passed -- 90 for a latitude, 180 for a longitude. A
    single range covering both accepts a latitude of 150, which is not a
    place. Junk returns None rather than raising, because one bad row
    upstream must not stop a backfill of ninety good ones.
    """
    if value in (None, ''):
        return None
    try:
        d = Decimal(str(value)).quantize(Decimal('0.000001'))
    except (InvalidOperation, ValueError, TypeError):
        return None
    return d if -limit <= d <= limit else None


def position(data):
    """(lat, lon) from an adapted course, or (None, None) if unusable.

    **0,0 is rejected as a PAIR.** It is a real point in the Atlantic, no
    golf course is there, and it is what a value defaulted rather than left
    absent looks like. Either one being zero alone is fine -- the equator
    and the Greenwich meridian both cross dry land.

    Worth having because the write below goes straight into the database:
    an unchecked coordinate is a course that silently moves, and a dot in
    the sea is harder to notice than a missing one.
    """
    lat = _coord(data.get('latitude'), 90)
    lon = _coord(data.get('longitude'), 180)
    if lat is None or lon is None or (lat == 0 and lon == 0):
        return None, None
    return lat, lon


class Command(BaseCommand):
    help = 'Re-fetch lat/lon for imported courses that are missing them.'

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true',
                            help='Commit. Without it, nothing is written.')
        parser.add_argument('--played-only', action='store_true',
                            help='Only courses that have a played round — the '
                                 'ones the map would show.')
        parser.add_argument('--limit', type=int, default=None,
                            help='Stop after N API calls.')

    def handle(self, *args, **o):
        qs = Course.objects.filter(latitude__isnull=True).exclude(
            golf_api_id='').exclude(golf_api_id__isnull=True)

        if o['played_only']:
            played = set(
                HoleScore.objects
                .filter(gross_score__isnull=False, player__is_phantom=False)
                .values_list('foursome__round_id', flat=True).distinct())
            ids = set(Round.objects.filter(id__in=played)
                      .values_list('course_id', flat=True))
            qs = qs.filter(id__in=ids)

        courses = list(qs.order_by('name'))
        if o['limit']:
            courses = courses[:o['limit']]

        if not courses:
            self.stdout.write('Nothing to backfill.')
            return

        # One API call per DISTINCT api id, not per course row: the same real
        # course is cloned into every account that added it, and they all want
        # the same answer. 20 rows across 7 clubs is not 20 calls.
        by_api = {}
        for c in courses:
            by_api.setdefault(c.golf_api_id, []).append(c)

        self.stdout.write(
            f'{len(courses)} course rows across {len(by_api)} distinct '
            f'courses\n')

        from services.golf_api_client import fetch_course

        found = failed = written = 0
        for api_id, rows in sorted(by_api.items(),
                                   key=lambda kv: kv[1][0].name):
            name = rows[0].name
            try:
                data = fetch_course(api_id)
            except Exception as exc:                       # noqa: BLE001
                failed += 1
                self.stdout.write(self.style.WARNING(
                    f'  FETCH FAILED  {name}  ({api_id}): {exc}'))
                continue

            lat, lon = position(data)
            if lat is None or lon is None:
                failed += 1
                self.stdout.write(self.style.WARNING(
                    f'  NO COORDS     {name}  ({api_id}) — upstream has none '
                    f'that can be used'))
                continue

            found += 1
            country = data.get('country') or ''
            city = data.get('city') or ''
            state = data.get('state') or ''
            self.stdout.write(
                f'  {lat:>10.5f},{lon:>11.5f}  {country[:14]:<14} '
                f'{name}  (x{len(rows)})')

            if not o['apply']:
                continue

            with transaction.atomic():
                for c in rows:
                    c.latitude, c.longitude = lat, lon
                    # Only FILL blanks for the text fields — a club may have
                    # corrected its own city, and a backfill of coordinates
                    # has no business overwriting that.
                    c.city = c.city or city
                    c.state = c.state or state
                    c.country = c.country or country
                    c.save(update_fields=['latitude', 'longitude',
                                          'city', 'state', 'country'])
                    written += 1
                # The catalog too, so the next account to clone this course
                # starts with the coordinates instead of needing this again.
                CatalogCourse.objects.filter(
                    golf_api_id=api_id, latitude__isnull=True
                ).update(latitude=lat, longitude=lon)

        self.stdout.write('')
        verb = 'written' if o['apply'] else 'would write'
        self.stdout.write(self.style.MIGRATE_HEADING(
            f'{found} courses located, {failed} could not be — '
            f'{verb} {written if o["apply"] else sum(len(r) for r in by_api.values())} rows'))
        if not o['apply']:
            self.stdout.write('Dry run. Re-run with --apply to commit.')
