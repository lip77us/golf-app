"""
uncurate_catalog_tees — bulk-clear the `curated` flag on STANDARD catalog tees
so GolfCourseAPI (USGA) re-imports become authoritative for their slope /
rating / holes and fan out to account copies.

A curated CatalogTee is SKIPPED by services.catalog.upsert_catalog_course, so a
re-import can't update it and CatalogCourse.data_version never bumps — the
lazy account propagation (TeeListView) stays dormant for it.  This flips
curated→False / origin→'api' across the whole catalog in one pass so the
re-import → propagate chain can actually fire.

SAFEGUARD — combos / local-only tees are HELD BACK by default.  Names containing
'/', 'combo', 'sixes' or '6s' don't exist in GolfCourseAPI, so un-curating one
would let the NEXT re-import DELETE it (upsert drops uncurated tees the API no
longer returns).  Pass --include-combos to flip those too (you almost never
want this).  Your account-level 'White-Sixes' course isn't in the catalog at
all, so it's untouched regardless.

Dry-run by default; pass --apply to write.  Reversible via
`mark_catalog_curated --name "<course>"` (re-protects).

    python manage.py uncurate_catalog_tees                    # preview ALL courses
    python manage.py uncurate_catalog_tees --golf-api-id 19641  # just Tilden
    python manage.py uncurate_catalog_tees --apply

NEXT STEPS after --apply: the catalog still holds its OLD tee data until you
RE-IMPORT each course from GolfCourseAPI (that's what pulls USGA values in and
bumps data_version).  Make sure GolfCourseAPI matches GHIN BEFORE re-importing.
Account copies then pick it up via the tee picker's lazy sync (or run
`sync_catalog_tees --name "<course>" --apply`).
"""
from django.core.management.base import BaseCommand, CommandError


def _is_local_only(name: str) -> bool:
    """True for combo / re-rated local tees that GolfCourseAPI won't have — so
    they must stay curated or a re-import would delete them."""
    n = (name or '').lower()
    return ('/' in n) or ('combo' in n) or ('sixes' in n) or ('6s' in n)


class Command(BaseCommand):
    help = "Un-curate standard catalog tees so API re-imports (USGA) drive them."

    def add_arguments(self, parser):
        parser.add_argument('--name', help='Limit to catalog courses matching this name (substring).')
        parser.add_argument('--golf-api-id', help='Limit to one catalog course by exact golf_api_id.')
        parser.add_argument('--include-combos', action='store_true',
                            help='Also un-curate combo/local-only tees (risky — they get '
                                 'deleted on the next re-import).')
        parser.add_argument('--apply', action='store_true',
                            help='Write the change (default is a dry-run).')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse

        qs = CatalogCourse.objects.prefetch_related('tees').order_by('name')
        if opts.get('golf_api_id'):
            qs = qs.filter(golf_api_id=str(opts['golf_api_id']))
        elif opts.get('name'):
            qs = qs.filter(name__icontains=opts['name'])

        courses = list(qs)
        if not courses:
            raise CommandError('No catalog course matched.')

        include_combos = opts['include_combos']
        apply = opts['apply']
        flipped = held = 0
        flip_ids = []
        skipped_synthetic = []

        for cc in courses:
            curated = [t for t in cc.tees.all() if t.curated]
            if not curated:
                continue
            # Synthetic keys ('manual-…' / 'local-…') have NO GolfCourseAPI
            # source, so nothing will ever re-import to drive them — un-curating
            # is pointless and just removes protection.  Keep them curated until
            # they're (re)added to GolfCourseAPI with a real id.
            if cc.golf_api_id.startswith(('manual-', 'local-')):
                skipped_synthetic.append(cc)
                self.stdout.write(self.style.WARNING(
                    f"\n{cc.name} [golf_api_id={cc.golf_api_id}] — SKIP "
                    f"(no GolfCourseAPI source; {len(curated)} tee(s) stay curated)"))
                continue
            to_flip, to_hold = [], []
            for t in curated:
                if _is_local_only(t.tee_name) and not include_combos:
                    to_hold.append(t)
                else:
                    to_flip.append(t)

            self.stdout.write(
                f"\n{cc.name} [golf_api_id={cc.golf_api_id}] "
                f"— {len(to_flip)} to un-curate, {len(to_hold)} held")
            for t in to_flip:
                self.stdout.write(f"    FLIP  {t.tee_name} ({t.sex or 'unisex'}) → api/uncurated")
            for t in to_hold:
                self.stdout.write(self.style.WARNING(
                    f"    HOLD  {t.tee_name} ({t.sex or 'unisex'}) — combo/local-only"))

            flipped += len(to_flip)
            held += len(to_hold)
            flip_ids += [t.pk for t in to_flip]

        if apply and flip_ids:
            from core.models import CatalogTee
            CatalogTee.objects.filter(pk__in=flip_ids).update(curated=False, origin='api')

        verb = 'Un-curated' if apply else 'Would un-curate'
        synthetic_note = (f"; skipped {len(skipped_synthetic)} synthetic-id course(s)"
                          if skipped_synthetic else '')
        self.stdout.write(self.style.SUCCESS(
            f"\n{verb} {flipped} tee(s); held {held} combo/local-only tee(s)"
            f"{synthetic_note}."))
        if not apply:
            self.stdout.write('Re-run with --apply to commit.')
        elif flipped:
            self.stdout.write(
                'Next: re-import each course from GolfCourseAPI (ensure it matches '
                'GHIN first), then account copies sync via the tee picker.')
