"""List the courses actually PLAYED on Halved.

Courses are per-account CLONES (see "Shared course catalog + copy-on-add" in
CLAUDE.md), so one real course exists once per account — and a course added by
paste carries no ``golf_api_id`` while an imported one does. Keying on that id
therefore SPLITS a course two clubs reached by different routes, which is why
this groups on the normalised NAME: that is what a person means by "a course".

A differently-named variant stays separate on purpose. "Tilden Park GC with
sixes" is a custom card somebody built, not the same course, and merging it
would hide that somebody is playing a hand-made copy.

"Played" means a round carrying at least one real gross score. A round that
was created and never started is not a course anyone played — counting it
would make the list an inventory of what people ADDED, which is a different
question and already answerable from Course.
"""
import csv
import re
import sys
from collections import defaultdict

from django.core.management.base import BaseCommand

from scoring.models import HoleScore
from tournament.models import Round


def _norm(s):
    return re.sub(r'[^a-z0-9]+', ' ', (s or '').lower()).strip()


class Command(BaseCommand):
    help = 'Courses that have actually been played, most-played first.'

    def add_arguments(self, parser):
        parser.add_argument('--csv', action='store_true',
                            help='Emit CSV on stdout instead of a table.')
        parser.add_argument('--account', default=None,
                            help='Limit to one account by name.')
        parser.add_argument('--since', default=None, metavar='YYYY-MM-DD',
                            help='Only rounds on or after this date.')
        parser.add_argument('--include-unplayed', action='store_true',
                            help='Also count rounds with no score posted.')
        parser.add_argument('--raw', action='store_true',
                            help='One row per Course record, ungrouped — the '
                                 'per-account clones kept apart so you can '
                                 'dedupe them yourself.')

    def handle(self, *args, **o):
        rounds = Round.objects.select_related('course', 'account')
        if o['account']:
            rounds = rounds.filter(account__name=o['account'])
        if o['since']:
            rounds = rounds.filter(date__gte=o['since'])

        if not o['include_unplayed']:
            played = set(
                HoleScore.objects
                .filter(gross_score__isnull=False, player__is_phantom=False)
                .values_list('foursome__round_id', flat=True).distinct())
            rounds = rounds.filter(id__in=played)

        if o['raw']:
            return self._raw(rounds, as_csv=o['csv'])

        groups = defaultdict(lambda: {
            'name': '', 'where': '', 'accounts': set(), 'copies': set(),
            'rounds': 0, 'first': None, 'last': None, 'api_id': ''})

        for r in rounds:
            c = r.course
            if c is None:
                continue
            g = groups[_norm(c.name)]
            g['name'] = g['name'] or c.name
            g['accounts'].add(r.account_id)
            g['copies'].add(c.id)
            g['rounds'] += 1
            g['api_id'] = g['api_id'] or (c.golf_api_id or '')
            if not g['where']:
                g['where'] = ', '.join(x for x in (c.city, c.state) if x)
            if r.date:
                g['first'] = min(g['first'] or r.date, r.date)
                g['last'] = max(g['last'] or r.date, r.date)

        rows = sorted(groups.values(), key=lambda g: (-g['rounds'], g['name']))

        if o['csv']:
            w = csv.writer(sys.stdout)
            w.writerow(['course', 'location', 'rounds', 'clubs', 'copies',
                        'first_played', 'last_played', 'golf_api_id'])
            for g in rows:
                w.writerow([g['name'], g['where'], g['rounds'],
                            len(g['accounts']), len(g['copies']),
                            g['first'] or '', g['last'] or '', g['api_id']])
            return

        clubs = len(set().union(*(g['accounts'] for g in rows))) if rows else 0
        self.stdout.write('')
        self.stdout.write(self.style.MIGRATE_HEADING(
            f'{len(rows)} courses played · '
            f'{sum(g["rounds"] for g in rows)} rounds · {clubs} clubs'))
        self.stdout.write('')
        self.stdout.write(f'{"rounds":>6} {"clubs":>6} {"copies":>6}  '
                          f'{"last played":<12} course')
        self.stdout.write('-' * 78)
        for g in rows:
            where = f'  ({g["where"]})' if g['where'] else ''
            self.stdout.write(
                f'{g["rounds"]:>6} {len(g["accounts"]):>6} '
                f'{len(g["copies"]):>6}  {str(g["last"] or ""):<12} '
                f'{g["name"]}{where}')
        self.stdout.write('')

    def _raw(self, rounds, *, as_csv):
        """One row per Course record — no grouping at all.

        The clones stay apart: a course five clubs added is five rows, and a
        pasted copy sits beside the imported one it duplicates. That is the
        honest shape of the data, and it is what you want when you intend to
        dedupe by hand rather than trust a rule.
        """
        per = defaultdict(lambda: {'rounds': 0, 'first': None, 'last': None,
                                   'course': None, 'account': ''})
        for r in rounds:
            c = r.course
            if c is None:
                continue
            g = per[c.id]
            g['course'] = c
            g['account'] = r.account.name if r.account_id else ''
            g['rounds'] += 1
            if r.date:
                g['first'] = min(g['first'] or r.date, r.date)
                g['last'] = max(g['last'] or r.date, r.date)

        rows = sorted(per.values(),
                      key=lambda g: (g['course'].name.lower(), g['account']))

        if as_csv:
            w = csv.writer(sys.stdout)
            w.writerow(['course_id', 'course', 'city', 'state', 'golf_api_id',
                        'account', 'rounds', 'first_played', 'last_played'])
            for g in rows:
                c = g['course']
                w.writerow([c.id, c.name, c.city or '', c.state or '',
                            c.golf_api_id or '', g['account'], g['rounds'],
                            g['first'] or '', g['last'] or ''])
            return

        self.stdout.write('')
        self.stdout.write(self.style.MIGRATE_HEADING(
            f'{len(rows)} course records with a played round'))
        self.stdout.write('')
        self.stdout.write(f'{"id":>6} {"rnds":>5}  {"last":<12} '
                          f'{"api id":<12} {"club":<22} course')
        self.stdout.write('-' * 100)
        for g in rows:
            c = g['course']
            where = ', '.join(x for x in (c.city, c.state) if x)
            self.stdout.write(
                f'{c.id:>6} {g["rounds"]:>5}  {str(g["last"] or ""):<12} '
                f'{(c.golf_api_id or "-"):<12} {g["account"][:22]:<22} '
                f'{c.name}{"  (" + where + ")" if where else ""}')
        self.stdout.write('')
