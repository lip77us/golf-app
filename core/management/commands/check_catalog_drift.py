"""
check_catalog_drift — compare each catalog course against the LIVE GolfCourseAPI
data and report where they differ, so you can decide what to fix upstream at
https://golfcourseapi.com/course-update (GHIN is the source of truth).

Read-only: fetches from GolfCourseAPI and diffs against the stored CatalogTees.
Nothing is written.  Only courses with a REAL golf_api_id are checked (synthetic
manual-/local-/seed- courses have no upstream to compare to).

For each matched tee (by name + sex) it reports slope / course-rating / total-par
/ per-hole (par + stroke index) differences as OURS→GCAPI, flags when GCAPI's own
hole data is INCOMPLETE (0 sentinels — worth adding upstream), and lists tees that
exist only on one side.  Throttled for the API rate limit.

    python manage.py check_catalog_drift                 # all real-id courses
    python manage.py check_catalog_drift --golf-api-id tq7659nk
    python manage.py check_catalog_drift --name "Tilden"
    python manage.py check_catalog_drift --show-synced   # also list in-sync tees
    python manage.py check_catalog_drift --sleep 8       # more spacing if throttled
"""
import time
from decimal import Decimal

from django.core.management.base import BaseCommand, CommandError

_SYNTHETIC = ('manual-', 'local-', 'seed-')


def _hole_geo(holes):
    return [(h['number'], h['par'], h['stroke_index'])
            for h in sorted(holes, key=lambda x: x['number'])]


def _api_incomplete(api_tee) -> bool:
    return any(h['par'] == 0 or h['stroke_index'] == 0 for h in api_tee['holes'])


class Command(BaseCommand):
    help = "Report where catalog courses differ from live GolfCourseAPI data."

    def add_arguments(self, parser):
        parser.add_argument('--name', help='Limit to catalog courses matching (substring).')
        parser.add_argument('--golf-api-id', help='Limit to one course by exact golf_api_id.')
        parser.add_argument('--show-synced', action='store_true',
                            help='Also list tees that are already in sync.')
        parser.add_argument('--sleep', type=float, default=6.0,
                            help='Seconds between course fetches (rate-limit spacing).')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse
        from services.golf_api_client import fetch_course

        def fetch_retry(cid, tries=3):
            for i in range(tries):
                try:
                    return fetch_course(cid)
                except Exception as e:
                    if '429' in str(e) and i < tries - 1:
                        time.sleep(20)
                        continue
                    raise

        qs = CatalogCourse.objects.prefetch_related('tees').order_by('name')
        if opts.get('golf_api_id'):
            qs = qs.filter(golf_api_id=str(opts['golf_api_id']))
        elif opts.get('name'):
            qs = qs.filter(name__icontains=opts['name'])

        courses = [c for c in qs if not c.golf_api_id.startswith(_SYNTHETIC)]
        skipped = [c for c in qs if c.golf_api_id.startswith(_SYNTHETIC)]
        if not courses:
            raise CommandError('No real-id catalog course matched.')

        show_synced = opts['show_synced']
        sleep = opts['sleep']
        need_update, in_sync, errored, incomplete = [], [], [], []

        for idx, cc in enumerate(courses):
            if idx:
                time.sleep(sleep)
            try:
                api = fetch_retry(cc.golf_api_id)
            except Exception as e:
                errored.append((cc, str(e)[:80]))
                self.stdout.write(self.style.ERROR(
                    f"\n{cc.name} [{cc.golf_api_id}] — FETCH FAILED: {str(e)[:80]}"))
                continue

            api_by_key = {(t['name'].casefold(), t['sex']): t for t in api['tees']}
            cat_by_key = {(t.tee_name.casefold(), t.sex): t for t in cc.tees.all()}

            lines, changed, has_incomplete = [], False, False
            for key, cat in cat_by_key.items():
                at = api_by_key.get(key)
                label = f"{cat.tee_name} ({cat.sex or 'unisex'})"
                if at is None:
                    lines.append(('local', f"    OURS ONLY   {label} — not in GCAPI (combo/custom)"))
                    continue
                diffs = []
                if cat.slope != at['slope']:
                    diffs.append(f"slope {cat.slope}→{at['slope']}")
                if Decimal(str(cat.course_rating)) != Decimal(str(at['course_rating'])):
                    diffs.append(f"rating {cat.course_rating}→{at['course_rating']}")
                if cat.par != at['par']:
                    diffs.append(f"par {cat.par}→{at['par']}")
                if _hole_geo(cat.holes) != _hole_geo(at['holes']):
                    n = sum(1 for a, b in zip(_hole_geo(cat.holes), _hole_geo(at['holes'])) if a != b)
                    diffs.append(f"hole par/SI differs ({n} hole(s))")
                if _api_incomplete(at):
                    has_incomplete = True
                    diffs.append('GCAPI hole data INCOMPLETE (0 sentinels)')

                if diffs:
                    changed = True
                    lines.append(('diff', f"    OURS→GCAPI  {label}: {', '.join(diffs)}"))
                elif show_synced:
                    lines.append(('same', f"    in sync     {label}"))

            for k in (set(api_by_key) - set(cat_by_key)):
                at = api_by_key[k]
                changed = True
                lines.append(('new', f"    GCAPI ONLY  {at['name']} ({at['sex']}) — we don't have it"))

            if changed:
                need_update.append(cc)
                if has_incomplete:
                    incomplete.append(cc)
                self.stdout.write(f"\n{cc.name} [{cc.golf_api_id}]")
                for kind, text in lines:
                    style = {'diff': self.style.WARNING, 'new': self.style.MIGRATE_HEADING}.get(kind)
                    self.stdout.write(style(text) if style else text)
            else:
                in_sync.append(cc)
                if show_synced:
                    self.stdout.write(self.style.SUCCESS(f"\n{cc.name} [{cc.golf_api_id}] — in sync"))

        self.stdout.write('\n' + '=' * 64)
        self.stdout.write(self.style.SUCCESS(
            f"{len(in_sync)} in sync, {len(need_update)} differ, "
            f"{len(errored)} fetch error(s), {len(skipped)} synthetic skipped."))
        if incomplete:
            self.stdout.write('\nGCAPI has INCOMPLETE hole data (worth fixing upstream):')
            for cc in incomplete:
                self.stdout.write(f"  • {cc.name} ({cc.golf_api_id})")
        if need_update:
            self.stdout.write('\nCourses that differ (review OURS→GCAPI above):')
            for cc in need_update:
                self.stdout.write(f"  • {cc.name} ({cc.golf_api_id})")
