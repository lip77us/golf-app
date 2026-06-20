"""
core/management/commands/seed_corica_north.py
---------------------------------------------
Create (or update, idempotently) the North course at Corica Park (Alameda, CA)
in a given account, with all five men's tees + three women's tees, hole pars,
stroke indexes, and per-tee yardages — transcribed from the physical scorecard
and verified against its OUT/IN/TOT subtotals.

Usage (run against Railway prod or locally):
    python manage.py seed_corica_north --account "Your Account Name"
    python manage.py seed_corica_north --account-id 12
    python manage.py seed_corica_north --account "..." --catalog   # also add to
                                                                    # the shared catalog

Re-running is safe: it matches the course by (account, name) and each tee by
(course, tee_name, sex), updating in place — it never deletes tees (which rounds
may reference).
"""
from decimal import Decimal

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from accounts.models import Account
from core.models import Course, Tee


COURSE_NAME = 'Corica Park Gc — North'
CITY, STATE, COUNTRY = 'Alameda', 'CA', 'USA'

# Hole 1..18.
PARS = [4, 5, 4, 3, 5, 3, 4, 4, 4,  4, 4, 4, 3, 5, 4, 5, 3, 4]      # OUT 36 / IN 36 = 72
# Stroke index = the scorecard "Hcp" column (front = odds, back = evens).
STROKE_INDEX = [11, 15, 9, 5, 13, 7, 1, 3, 17,  10, 2, 14, 6, 12, 16, 8, 18, 4]

YARDS = {
    'Black': [376, 493, 377, 185, 498, 156, 407, 283, 376,
              409, 451, 338, 161, 503, 295, 513, 208, 353],
    'Blue':  [343, 485, 366, 150, 479, 141, 401, 243, 363,
              401, 431, 333, 153, 497, 295, 494, 171, 341],
    'White': [326, 471, 348, 126, 425, 123, 390, 225, 341,
              382, 400, 324, 145, 467, 278, 457, 158, 353],
    'Red':   [310, 439, 320, 107, 413, 85, 305, 209, 323,
              371, 379, 308, 123, 430, 264, 439, 151, 313],
    'Gold':  [299, 417, 296, 98, 405, 64, 285, 201, 303,
              363, 364, 294, 105, 420, 186, 426, 141, 306],
}

# (tee_name, sex, course_rating, slope, sort_priority, yardage_key)
# Women's tees reuse the men's same-colour yardages + stroke indexes (the card
# prints one Hcp column); only rating/slope differ.
TEES = [
    ('Black', 'M', '70.5', 118, 10, 'Black'),
    ('Blue',  'M', '69.1', 117, 20, 'Blue'),
    ('White', 'M', '67.8', 111, 30, 'White'),
    ('Red',   'M', '65.4', 107, 40, 'Red'),
    ('Gold',  'M', '63.9', 103, 50, 'Gold'),
    ('White', 'W', '72.8', 120, 60, 'White'),
    ('Red',   'W', '70.1', 115, 70, 'Red'),
    ('Gold',  'W', '68.3', 110, 80, 'Gold'),
]


def _holes_for(yardage_key):
    yards = YARDS[yardage_key]
    return [
        {'number': i + 1, 'par': PARS[i],
         'stroke_index': STROKE_INDEX[i], 'yards': yards[i]}
        for i in range(18)
    ]


class Command(BaseCommand):
    help = 'Create/update the North course at Corica Park in an account.'

    def add_arguments(self, parser):
        parser.add_argument('--account', help='Account name to add the course to.')
        parser.add_argument('--account-id', type=int,
                            help='Account id (alternative to --account).')
        parser.add_argument('--name', default=COURSE_NAME,
                            help=f'Course name (default "{COURSE_NAME}").')
        parser.add_argument('--catalog', action='store_true',
                            help='Also upsert into the shared course catalog.')

    def _account_names(self):
        return ', '.join(
            Account.objects.order_by('name').values_list('name', flat=True)[:50])

    def _resolve_account(self, opts):
        if opts.get('account_id'):
            try:
                return Account.objects.get(pk=opts['account_id'])
            except Account.DoesNotExist:
                raise CommandError(f"No account with id {opts['account_id']}.")
        try:
            return Account.objects.get(name=opts['account'])
        except Account.DoesNotExist:
            raise CommandError(
                f"No account named {opts['account']!r}. "
                f"Accounts: {self._account_names()}")

    @transaction.atomic
    def handle(self, *args, **opts):
        name = opts['name']
        want_account = bool(opts.get('account') or opts.get('account_id'))
        want_catalog = opts['catalog']
        if not (want_account or want_catalog):
            raise CommandError(
                'Nothing to do. Pass --catalog (shared catalog) and/or '
                '--account "<name>". Accounts: ' + self._account_names())

        # Sanity-check the transcription before writing anything.
        assert sum(PARS) == 72, 'par total != 72'
        assert sorted(STROKE_INDEX) == list(range(1, 19)), 'stroke index not 1..18'

        if want_catalog:
            self._upsert_catalog(name)
        if want_account:
            self._upsert_account_course(self._resolve_account(opts), name)
        self.stdout.write(self.style.SUCCESS('Done.'))

    def _upsert_account_course(self, acct, name):
        course, created = Course.objects.get_or_create(
            account=acct, name=name,
            defaults={'city': CITY, 'state': STATE, 'country': COUNTRY},
        )
        if not created:
            course.city, course.state, course.country = CITY, STATE, COUNTRY
            course.save(update_fields=['city', 'state', 'country'])

        for tee_name, sex, rating, slope, priority, ykey in TEES:
            tee, t_created = Tee.objects.update_or_create(
                course=course, tee_name=tee_name, sex=sex,
                defaults={
                    'slope': slope,
                    'course_rating': Decimal(rating),
                    'par': 72,
                    'holes': _holes_for(ykey),
                    'sort_priority': priority,
                },
            )
            out = sum(h['yards'] for h in tee.holes[:9])
            inn = sum(h['yards'] for h in tee.holes[9:])
            self.stdout.write(
                f"  {'+' if t_created else '~'} {tee_name} ({sex}) "
                f"{rating}/{slope}  OUT {out} IN {inn} TOT {out + inn}")
        verb = 'Created' if created else 'Updated'
        self.stdout.write(
            f"  account '{acct.name}': {verb} '{name}' "
            f"({len(TEES)} tees, par 72).")

    def _upsert_catalog(self, name):
        from services.catalog import upsert_catalog_course
        api_course = {
            'city': CITY, 'state': STATE, 'country': COUNTRY,
            'latitude': None, 'longitude': None,
            'tees': [
                {'name': tn, 'sex': sx, 'slope': sl,
                 'course_rating': Decimal(rt), 'par': 72,
                 'holes': _holes_for(yk)}
                for tn, sx, rt, sl, _pri, yk in TEES
            ],
        }
        cc = upsert_catalog_course(api_course, 'manual-corica-north', name)
        self.stdout.write(
            f"  catalog: upserted '{cc.name}' ({cc.tees.count()} tees).")
