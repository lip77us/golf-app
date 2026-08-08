"""
suggest_gcapi_ids — for every catalog course still on a dead numeric GolfCourseAPI
id, search GCAPI by name and list the current (alphanumeric) candidates, so you
can confirm the mapping before re-stamping.  Read-only; throttled for the API
rate limit.
"""
import time

from django.core.management.base import BaseCommand


def _query_for(name: str) -> str:
    base = name.split('—')[0].strip()
    toks = [t for t in base.split() if t.lower() not in ('gc', 'gl', 'cc', 'g&cc')]
    return ' '.join(toks) or base


class Command(BaseCommand):
    help = "List current GCAPI id candidates for catalog courses on dead numeric ids."

    def add_arguments(self, parser):
        parser.add_argument('--sleep', type=float, default=5.0,
                            help='Seconds between searches (rate-limit spacing).')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse
        from services.golf_api_client import search_courses

        def search_retry(q, tries=3):
            for i in range(tries):
                try:
                    return search_courses(q)
                except Exception as e:
                    if '429' in str(e) and i < tries - 1:
                        time.sleep(20)
                        continue
                    raise

        courses = [c for c in CatalogCourse.objects.all().order_by('name')
                   if c.golf_api_id and c.golf_api_id.isdigit()]

        for c in courses:
            q = _query_for(c.name)
            try:
                hits = search_retry(q)
            except Exception as e:
                self.stdout.write(f'### {c.name} [old={c.golf_api_id}] query="{q}" -> ERROR {str(e)[:80]}')
                time.sleep(opts['sleep'])
                continue
            self.stdout.write(f'\n### {c.name}  [old={c.golf_api_id}]  query="{q}"  ({len(hits)} hits)')
            for h in hits[:5]:
                loc = ', '.join(p for p in (h.get('city'), h.get('state')) if p)
                self.stdout.write(f'    {h["id"]:>10}  |  {h.get("club_name","")} / {h.get("course_name","")}  |  {loc}')
            time.sleep(opts['sleep'])
