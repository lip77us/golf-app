"""
mark_catalog_curated — flip the `curated` flag on a catalog course's tees.

A curated CatalogTee is protected from GolfCourseAPI re-import overwrites (see
services/catalog.upsert_catalog_course + docs/catalog-curation-and-updates.md).

Use it two ways:
  * After hand-editing a catalog tee, PROTECT it so a re-import can't clobber it:
        python manage.py mark_catalog_curated --name "Metropolitan"
  * To deliberately ALLOW the API to refresh a course, UN-protect it first:
        python manage.py mark_catalog_curated --name "Some Course" --uncurate

Identify the course by name (substring) or exact golf_api_id. Dry-run by
default; pass --apply to write.
"""
from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "Protect (or un-protect) a catalog course's tees from API overwrite."

    def add_arguments(self, parser):
        parser.add_argument('--name', help='Catalog course name (substring).')
        parser.add_argument('--golf-api-id', help='Exact golf_api_id.')
        parser.add_argument('--uncurate', action='store_true',
                            help='Clear curated (allow API updates) instead of setting it.')
        parser.add_argument('--apply', action='store_true',
                            help='Write the change (default is a dry-run).')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse

        qs = CatalogCourse.objects.all()
        if opts.get('golf_api_id'):
            qs = qs.filter(golf_api_id=str(opts['golf_api_id']))
        elif opts.get('name'):
            qs = qs.filter(name__icontains=opts['name'])
        else:
            raise CommandError('Pass --name or --golf-api-id.')

        courses = list(qs)
        if not courses:
            raise CommandError('No catalog course matched.')
        if len(courses) > 1 and not opts.get('golf_api_id'):
            listing = '\n'.join(f'    - {c.name} [golf_api_id={c.golf_api_id}]'
                                for c in courses)
            raise CommandError(f'{len(courses)} courses match — narrow it or use '
                               f'--golf-api-id:\n{listing}')

        target = not opts['uncurate']  # True = protect, False = allow updates
        origin = 'manual' if target else 'api'
        apply = opts['apply']
        verb = ('PROTECT' if target else 'UN-PROTECT')

        total = 0
        for cc in courses:
            tees = cc.tees.all()
            changing = tees.exclude(curated=target)
            n = changing.count()
            total += n
            self.stdout.write(
                f"{cc.name} [golf_api_id={cc.golf_api_id}]: "
                f"{n}/{tees.count()} tee(s) → curated={target}")
            if apply and n:
                changing.update(curated=target, origin=origin)

        verb2 = 'Applied' if apply else 'Would set'
        self.stdout.write(self.style.SUCCESS(
            f"{verb2} curated={target} ({verb}) on {total} tee(s)."))
        if not apply:
            self.stdout.write('Re-run with --apply to commit.')
