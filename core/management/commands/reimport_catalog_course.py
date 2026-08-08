"""
reimport_catalog_course — refresh ONE catalog course from live GolfCourseAPI and
optionally propagate to the account copies.

Run `uncurate_catalog_tees` FIRST for this course, or upsert will skip the
curated standard tees and nothing changes.  Curated tees (combos, White-Sixes)
are intentionally left alone.  Slope/rating changes update in place; par /
stroke-index changes supersede played tees (scorecards stay frozen).

Dry-run by default; --apply to write; --propagate to also push to accounts.

    python manage.py reimport_catalog_course --golf-api-id tq7659nk --propagate --apply
"""
from django.core.management.base import BaseCommand, CommandError

_SYNTHETIC = ('manual-', 'local-', 'seed-')


class Command(BaseCommand):
    help = "Re-import one catalog course from GolfCourseAPI (refresh ratings/holes)."

    def add_arguments(self, parser):
        parser.add_argument('--golf-api-id')
        parser.add_argument('--name')
        parser.add_argument('--propagate', action='store_true',
                            help='Also push the refreshed catalog to account copies.')
        parser.add_argument('--skip-gate', action='store_true',
                            help='Bypass the import quality gate.')
        parser.add_argument('--apply', action='store_true',
                            help='Write (default is a dry-run).')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse, Course
        from services.golf_api_client import fetch_course
        from services.catalog import upsert_catalog_course, clone_catalog_to_account

        qs = CatalogCourse.objects.all()
        if opts.get('golf_api_id'):
            qs = qs.filter(golf_api_id=str(opts['golf_api_id']))
        elif opts.get('name'):
            qs = qs.filter(name__icontains=opts['name'])
        else:
            raise CommandError('Pass --name or --golf-api-id.')
        ccs = list(qs)
        if len(ccs) != 1:
            raise CommandError(f'{len(ccs)} catalog course(s) matched — narrow it.')
        cc = ccs[0]
        if cc.golf_api_id.startswith(_SYNTHETIC):
            raise CommandError(f'{cc.name} has a synthetic id ({cc.golf_api_id}); no GCAPI source.')

        api = fetch_course(cc.golf_api_id)
        self.stdout.write(f"{cc.name} [{cc.golf_api_id}] — GCAPI returned {len(api['tees'])} tee(s).")

        if not opts['skip_gate']:
            from services.course_quality import assert_course_quality, CourseQualityError
            try:
                assert_course_quality(api)
            except CourseQualityError as e:
                raise CommandError(f'Quality gate rejected the GCAPI data: {e.problems}')

        curated = [t.tee_name for t in cc.tees.all() if t.curated]
        if curated:
            self.stdout.write(self.style.WARNING(
                f"  curated (will be skipped by upsert): {', '.join(curated)}"))

        if not opts['apply']:
            self.stdout.write('Dry-run — re-run with --apply to write.')
            return

        before = cc.data_version
        cc = upsert_catalog_course(api, cc.golf_api_id, cc.name)
        self.stdout.write(self.style.SUCCESS(
            f"Catalog refreshed: data_version {before} → {cc.data_version}."))

        if opts['propagate']:
            n = 0
            for course in Course.objects.filter(golf_api_id=cc.golf_api_id):
                clone_catalog_to_account(cc, course.account, replace_tees=True)
                n += 1
            self.stdout.write(self.style.SUCCESS(f"Propagated to {n} account copy/copies."))
