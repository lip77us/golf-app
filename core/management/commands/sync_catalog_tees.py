"""
sync_catalog_tees — push a catalog course's CURRENT tees out to every account
that has a copy of it (the deferred "catalog → account propagation").

Accounts get copy-on-ADD clones of catalog courses, so a later correction to a
CatalogTee doesn't reach the copies on its own.  This command re-syncs those
copies from the catalog via services.catalog.clone_catalog_to_account(
replace_tees=True): tees are matched by (name, sex) and updated copy-on-write —
a tee already played in a round is RETIRED into an immutable revision (that
round's scorecard stays frozen) while a fresh current revision picks up the fix;
unplayed tees update in place; newly-added catalog tees are created; local
Tee.sort_priority is preserved.  Account tees NOT in the catalog are left alone.

Identify the catalog course by name or golf_api_id:

    # See what WOULD change across all accounts (dry-run is the default):
    python manage.py sync_catalog_tees --name "Tilden"

    # Actually apply it:
    python manage.py sync_catalog_tees --name "Tilden" --apply

    # Limit to one account first (e.g. your own) to sanity-check:
    python manage.py sync_catalog_tees --name "Tilden" --account "DemoClub" --apply

    # Or pin the exact catalog entry:
    python manage.py sync_catalog_tees --golf-api-id 12345 --apply

Finish your catalog edits (corrections + tee additions) BEFORE running with
--apply — the command reads the catalog as-is.
"""

from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "Propagate a catalog course's tees to every account that has a copy."

    def add_arguments(self, parser):
        parser.add_argument('--name',
                            help='Match the catalog course by name (case-insensitive substring).')
        parser.add_argument('--golf-api-id',
                            help='Match the catalog course by exact golf_api_id.')
        parser.add_argument('--account',
                            help='Limit to one account (name, case-insensitive).')
        parser.add_argument('--apply', action='store_true',
                            help='Actually write the changes (default is a dry-run).')

    def _find_catalog_course(self, opts):
        from core.models import CatalogCourse
        if opts.get('golf_api_id'):
            cc = CatalogCourse.objects.filter(golf_api_id=str(opts['golf_api_id'])).first()
            if cc is None:
                raise CommandError(f"No catalog course with golf_api_id={opts['golf_api_id']!r}.")
            return cc
        if opts.get('name'):
            matches = list(CatalogCourse.objects.filter(name__icontains=opts['name']))
            if not matches:
                raise CommandError(f"No catalog course matching name ~ {opts['name']!r}.")
            if len(matches) > 1:
                listing = '\n'.join(
                    f"    - {c.name}  [golf_api_id={c.golf_api_id}]" for c in matches)
                raise CommandError(
                    f"{len(matches)} catalog courses match name ~ {opts['name']!r} — "
                    f"pin one with --golf-api-id:\n{listing}")
            return matches[0]
        raise CommandError("Pass --name or --golf-api-id to identify the catalog course.")

    def handle(self, *args, **opts):
        from core.models import Course
        from services.catalog import clone_catalog_to_account
        from services.tee_revisions import _tee_is_referenced

        apply = opts['apply']
        cc = self._find_catalog_course(opts)
        catalog_tees = list(cc.tees.all())
        cat_by_key = {(t.tee_name.casefold(), t.sex): t for t in catalog_tees}

        self.stdout.write(
            f"Catalog course: {cc.name}  [golf_api_id={cc.golf_api_id}]  "
            f"({len(catalog_tees)} tees)")

        # Every account's copy of this course, keyed by golf_api_id.
        qs = (Course.objects
              .filter(golf_api_id=cc.golf_api_id)
              .select_related('account')
              .prefetch_related('tees'))
        if opts.get('account'):
            qs = qs.filter(account__name__iexact=opts['account'])
        courses = list(qs)

        if not courses:
            self.stdout.write(self.style.WARNING(
                "No account courses share this golf_api_id — nothing to sync. "
                "(If accounts hold Tilden under a different golf_api_id, the "
                "copy-on-add linkage has drifted; tell me and I'll add name "
                "matching.)"))
            return

        self.stdout.write(
            f"{'APPLYING to' if apply else 'DRY-RUN over'} {len(courses)} account "
            f"cop{'y' if len(courses) == 1 else 'ies'}:\n")

        totals = {'add': 0, 'update_inplace': 0, 'update_revision': 0, 'unchanged': 0}

        for course in courses:
            adds, inplace, revised, unchanged = [], [], [], []
            current_by_key = {
                (t.tee_name.casefold(), t.sex): t
                for t in course.tees.filter(superseded_by__isnull=True)
            }
            for ct in catalog_tees:
                existing = current_by_key.get((ct.tee_name.casefold(), ct.sex))
                if existing is None:
                    adds.append(ct.tee_name)
                elif existing.holes != ct.holes:
                    if _tee_is_referenced(existing):
                        revised.append(ct.tee_name)
                    else:
                        inplace.append(ct.tee_name)
                else:
                    unchanged.append(ct.tee_name)

            totals['add'] += len(adds)
            totals['update_inplace'] += len(inplace)
            totals['update_revision'] += len(revised)
            totals['unchanged'] += len(unchanged)

            # Only account tees that AREN'T in the catalog (left untouched).
            orphan = [t.tee_name for key, t in current_by_key.items()
                      if key not in cat_by_key]

            parts = []
            if adds:     parts.append(f"add {adds}")
            if revised:  parts.append(f"re-rate (played→new revision) {revised}")
            if inplace:  parts.append(f"update {inplace}")
            if unchanged: parts.append(f"{len(unchanged)} unchanged")
            if orphan:   parts.append(f"leave account-only {orphan}")
            self.stdout.write(f"  {course.account.name}: " + ('; '.join(parts) or 'nothing'))

            if apply:
                clone_catalog_to_account(cc, course.account, replace_tees=True)

        self.stdout.write("")
        verb = "Applied" if apply else "Would apply"
        self.stdout.write(self.style.SUCCESS(
            f"{verb}: {totals['add']} tee(s) added, "
            f"{totals['update_inplace']} updated in place, "
            f"{totals['update_revision']} re-rated as new revisions "
            f"(played rounds frozen), {totals['unchanged']} unchanged."))
        if not apply:
            self.stdout.write("Re-run with --apply to commit.")
