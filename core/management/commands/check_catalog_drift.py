"""
check_catalog_drift — compare each catalog course against the LIVE GolfCourseAPI
data and report what's out of sync, so you know which courses to re-import after
pushing changes upstream.

Read-only: fetches from GolfCourseAPI and diffs against the stored CatalogTees.
Nothing is written.  Only courses with a REAL golf_api_id are checked (synthetic
`manual-`/`local-` courses have no upstream to compare to).

For each matched tee (by name + sex) it flags slope / course-rating / total-par
/ per-hole (par + stroke index) differences, and notes when a differing tee is
CURATED (a re-import would be blocked until you run uncurate_catalog_tees) or
when GCAPI's own hole data is INCOMPLETE (0 sentinels — re-import would be
rejected by the quality gate).

    python manage.py check_catalog_drift                 # all real-id courses
    python manage.py check_catalog_drift --golf-api-id 19641
    python manage.py check_catalog_drift --name "Tilden"
    python manage.py check_catalog_drift --show-synced   # also list in-sync tees
"""
from decimal import Decimal

from django.core.management.base import BaseCommand, CommandError


def _hole_geo(holes):
    """(hole, par, stroke_index) tuples — the scoring-relevant geometry."""
    return [(h['number'], h['par'], h['stroke_index'])
            for h in sorted(holes, key=lambda x: x['number'])]


def _api_incomplete(api_tee) -> bool:
    return any(h['par'] == 0 or h['stroke_index'] == 0 for h in api_tee['holes'])


class Command(BaseCommand):
    help = "Report which catalog courses differ from live GolfCourseAPI data."

    def add_arguments(self, parser):
        parser.add_argument('--name', help='Limit to catalog courses matching (substring).')
        parser.add_argument('--golf-api-id', help='Limit to one course by exact golf_api_id.')
        parser.add_argument('--show-synced', action='store_true',
                            help='Also list tees that are already in sync.')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse
        from services.golf_api_client import fetch_course

        qs = CatalogCourse.objects.prefetch_related('tees').order_by('name')
        if opts.get('golf_api_id'):
            qs = qs.filter(golf_api_id=str(opts['golf_api_id']))
        elif opts.get('name'):
            qs = qs.filter(name__icontains=opts['name'])

        courses = [c for c in qs if not c.golf_api_id.startswith(('manual-', 'local-'))]
        skipped = [c for c in qs if c.golf_api_id.startswith(('manual-', 'local-'))]
        if not courses:
            raise CommandError('No real-id catalog course matched.')

        show_synced = opts['show_synced']
        need_update, in_sync, errored = [], [], []

        for cc in courses:
            try:
                api = fetch_course(cc.golf_api_id)
            except Exception as e:
                errored.append((cc, str(e)))
                self.stdout.write(self.style.ERROR(
                    f"\n{cc.name} [{cc.golf_api_id}] — FETCH FAILED: {e}"))
                continue

            api_by_key = {(t['name'].casefold(), t['sex']): t for t in api['tees']}
            cat_by_key = {(t.tee_name.casefold(), t.sex): t for t in cc.tees.all()}

            lines, changed_any = [], False
            for key, cat in cat_by_key.items():
                at = api_by_key.get(key)
                label = f"{cat.tee_name} ({cat.sex or 'unisex'})"
                if at is None:
                    lines.append(('local', f"    LOCAL-ONLY  {label} — not in GCAPI "
                                            f"(combo/custom; won't re-import)"))
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

                if not diffs:
                    if show_synced:
                        lines.append(('same', f"    in sync     {label}"))
                    continue

                changed_any = True
                tags = []
                if cat.curated:
                    tags.append('CURATED→blocked')
                if _api_incomplete(at):
                    tags.append('GCAPI-INCOMPLETE→gate-rejects')
                suffix = f"  [{', '.join(tags)}]" if tags else ''
                lines.append(('diff', f"    CHANGED     {label}: {', '.join(diffs)}{suffix}"))

            new_tees = [k for k in api_by_key if k not in cat_by_key]
            for k in new_tees:
                at = api_by_key[k]
                changed_any = True
                lines.append(('new', f"    NEW IN GCAPI {at['name']} ({at['sex']}) — add on re-import"))

            if changed_any:
                need_update.append(cc)
                self.stdout.write(f"\n{cc.name} [{cc.golf_api_id}]  data_version={cc.data_version}")
                for kind, text in lines:
                    style = {'diff': self.style.WARNING, 'new': self.style.MIGRATE_HEADING}.get(kind)
                    self.stdout.write(style(text) if style else text)
            else:
                in_sync.append(cc)
                if show_synced:
                    self.stdout.write(self.style.SUCCESS(f"\n{cc.name} [{cc.golf_api_id}] — in sync"))

        # ---- summary ----
        self.stdout.write('\n' + '=' * 60)
        self.stdout.write(self.style.SUCCESS(
            f"{len(need_update)} course(s) need updating, {len(in_sync)} in sync, "
            f"{len(errored)} fetch error(s), {len(skipped)} synthetic-id skipped."))
        if need_update:
            self.stdout.write('\nRe-import these (un-curate first if flagged CURATED):')
            for cc in need_update:
                self.stdout.write(f"  • {cc.name}  (golf_api_id={cc.golf_api_id})")
