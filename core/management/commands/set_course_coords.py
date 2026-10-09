"""Set coordinates by hand, for courses the API cannot reach.

A pasted course was never fetched from anywhere, so it has no `golf_api_id`
and `backfill_course_coords` cannot help it. Somebody has to look it up.

Geocoding by name is deliberately not done anywhere in this repo: the
homepage map's whole claim is that it shows where rounds were really played,
and a guessed coordinate is a dot nobody can check.

    python manage.py set_course_coords 2:43.1878,-124.3907 10:36.6177,-121.9166
    python manage.py set_course_coords --from-csv coords.csv --apply

CSV is `course_id,lat,lon[,country]` with an optional header.
Dry-run by default; `--apply` commits.
"""
import csv

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from core.models import Course


class Command(BaseCommand):
    help = 'Set lat/lon on courses by id, for ones the API cannot resolve.'

    def add_arguments(self, parser):
        parser.add_argument('pairs', nargs='*',
                            help='id:lat,lon — repeatable.')
        parser.add_argument('--from-csv', default=None,
                            help='course_id,lat,lon[,country], header optional.')
        parser.add_argument('--country', default='United States',
                            help='Stored on any course that has none. The '
                                 'homepage map plots US only, and courses_played '
                                 '--map maps the name to a 2-letter code.')
        parser.add_argument('--apply', action='store_true')

    def handle(self, *args, **o):
        entries = []
        for p in o['pairs']:
            try:
                cid, rest = p.split(':', 1)
                lat, lon = rest.split(',')
                entries.append((int(cid), float(lat), float(lon), None))
            except ValueError as exc:
                raise CommandError(f'cannot read {p!r}: expected id:lat,lon') from exc

        if o['from_csv']:
            with open(o['from_csv']) as fh:
                for row in csv.reader(fh):
                    if not row or not row[0].strip():
                        continue
                    if not row[0].strip().lstrip('-').isdigit():
                        continue                      # header
                    entries.append((int(row[0]), float(row[1]), float(row[2]),
                                    row[3].strip() if len(row) > 3 else None))

        if not entries:
            raise CommandError('nothing to set — pass id:lat,lon or --from-csv')

        found = Course.objects.in_bulk([e[0] for e in entries])
        missing = [e[0] for e in entries if e[0] not in found]
        if missing:
            raise CommandError(f'no such course id: {missing}')

        for cid, lat, lon, country in entries:
            c = found[cid]
            # A coordinate that is already there is left alone unless it
            # actually differs — this command is for FILLING blanks, and a
            # silent overwrite of something the API fetched would be the
            # hand-typed value quietly winning.
            had = '' if c.latitude is None else f'  (was {c.latitude},{c.longitude})'
            self.stdout.write(
                f'  {cid:>4}  {lat:>10.5f},{lon:>11.5f}  {c.name}{had}')

        if not o['apply']:
            self.stdout.write('\nDry run. Re-run with --apply to commit.')
            return

        with transaction.atomic():
            for cid, lat, lon, country in entries:
                c = found[cid]
                c.latitude, c.longitude = lat, lon
                c.country = c.country or country or o['country']
                c.save(update_fields=['latitude', 'longitude', 'country'])
        self.stdout.write(self.style.SUCCESS(f'\n{len(entries)} courses set.'))
