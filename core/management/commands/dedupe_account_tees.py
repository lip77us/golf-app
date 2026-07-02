"""
dedupe_account_tees — retire duplicate CURRENT tees in account courses.

An account course can end up with more than one CURRENT (non-superseded) tee
sharing the same (name, sex) — e.g. from repeated imports or a catalog sync that
couldn't collapse a (name, sex) collision (the sync keys tees by (name, sex), so
it can only track one per key). This keeps ONE keeper per group and RETIRES the
rest via `superseded_by` (copy-on-write): a retired tee that was already played
stays frozen for that round; unplayed retired tees just drop out of the current
tee pickers. Nothing is deleted, so PROTECT'd history is safe.

Keeper selection:
  * If the course maps to a CatalogCourse (by golf_api_id), the keeper is the
    current tee whose (slope, course_rating, holes) matches the catalog tee for
    that (name, sex) — i.e. the correct, in-sync copy.
  * Otherwise (no catalog, or no current tee matches it) the keeper is the sole
    played tee if there's exactly one, else the first — flagged as a heuristic.

    # dry-run over a course (default):
    python manage.py dedupe_account_tees --name "Tilden"
    # apply:
    python manage.py dedupe_account_tees --name "Tilden" --apply
    # scope to one account:
    python manage.py dedupe_account_tees --name "Tilden" --account "Paul" --apply
"""

from collections import defaultdict

from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = ("Retire duplicate current tees (same name+sex) in account courses, "
            "keeping the catalog-matching copy.")

    def add_arguments(self, parser):
        parser.add_argument('--name',
                            help='Match the account course(s) by name (icontains).')
        parser.add_argument('--golf-api-id',
                            help='Match the account course(s) by exact golf_api_id.')
        parser.add_argument('--account',
                            help='Limit to one account (name, icontains).')
        parser.add_argument('--apply', action='store_true',
                            help='Actually write the changes (default is a dry-run).')

    def handle(self, *args, **opts):
        from core.models import Course, CatalogCourse
        from services.tee_revisions import _tee_is_referenced

        apply = opts['apply']

        qs = Course.objects.select_related('account').prefetch_related('tees')
        if opts.get('golf_api_id'):
            qs = qs.filter(golf_api_id=str(opts['golf_api_id']))
        elif opts.get('name'):
            qs = qs.filter(name__icontains=opts['name'])
        else:
            raise CommandError("Pass --name or --golf-api-id to identify the course(s).")
        if opts.get('account'):
            qs = qs.filter(account__name__icontains=opts['account'])

        courses = list(qs)
        if not courses:
            raise CommandError("No matching account courses.")

        # Catalog reference: golf_api_id → {(name.casefold, sex): (slope, rating, holes)}
        cat_by_apiid = {
            cc.golf_api_id: {
                (t.tee_name.casefold(), t.sex): (t.slope, str(t.course_rating), t.holes)
                for t in cc.tees.all()
            }
            for cc in CatalogCourse.objects.prefetch_related('tees')
        }

        self.stdout.write(
            f"{'APPLYING' if apply else 'DRY-RUN'} over {len(courses)} account "
            f"cop{'y' if len(courses) == 1 else 'ies'}:\n")

        total_retired = 0
        for course in courses:
            catmap = cat_by_apiid.get(course.golf_api_id, {})
            groups = defaultdict(list)
            for t in course.tees.filter(superseded_by__isnull=True):
                groups[(t.tee_name.casefold(), t.sex)].append(t)

            for key, tees in groups.items():
                if len(tees) <= 1:
                    continue

                cat = catmap.get(key)
                keeper = None
                note = ""
                if cat is not None:
                    matches = [t for t in tees
                               if (t.slope, str(t.course_rating), t.holes) == cat]
                    keeper = matches[0] if matches else None
                if keeper is None:
                    played = [t for t in tees if _tee_is_referenced(t)]
                    keeper = played[0] if len(played) == 1 else tees[0]
                    note = "  (no catalog match — heuristic keeper)"

                losers = [t for t in tees if t.pk != keeper.pk]
                loser_desc = ', '.join(
                    f"pk{t.pk}({t.slope}/{t.course_rating},"
                    f"{'played' if _tee_is_referenced(t) else 'unplayed'})"
                    for t in losers)
                self.stdout.write(
                    f"  {course.account.name} · {key[0]}/{key[1]} ×{len(tees)}: "
                    f"keep pk{keeper.pk} ({keeper.slope}/{keeper.course_rating}), "
                    f"retire {loser_desc}{note}")

                if apply:
                    for t in losers:
                        t.superseded_by = keeper
                        t.save(update_fields=['superseded_by'])
                total_retired += len(losers)

        self.stdout.write("")
        verb = "Retired" if apply else "Would retire"
        self.stdout.write(self.style.SUCCESS(
            f"{verb} {total_retired} duplicate tee(s) "
            f"(superseded → keeper; played rounds stay frozen)."))
        if not apply:
            self.stdout.write("Re-run with --apply to commit.")
