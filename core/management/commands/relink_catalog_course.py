"""
relink_catalog_course — repoint a catalog course from an old/synthetic golf_api_id
to a new GolfCourseAPI slug, then un-curate + re-import + propagate so it carries
live GCAPI data and future USGA updates.

Use it when GCAPI ADDS a course you'd been carrying as a hand-built synthetic
(`manual-…`/`local-…`) entry — e.g. after they add a course you emailed them.

    manage.py relink_catalog_course --from manual-sheep-ranch --to 8mcwprkp          # dry-run
    manage.py relink_catalog_course --from manual-sheep-ranch --to 8mcwprkp --apply

Dry-run by DEFAULT (runs inside a transaction and rolls back). --apply commits,
all-or-nothing. Idempotent: once relinked, re-running with the SAME --to (and the
old --from gone) just re-imports.
"""
from django.core.management import call_command
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction


class _DryRunRollback(Exception):
    pass


class Command(BaseCommand):
    help = "Repoint a catalog course to a new GCAPI slug, then reimport + propagate."

    def add_arguments(self, parser):
        parser.add_argument('--from', dest='from_id', required=True,
                            help='Current golf_api_id (e.g. manual-sheep-ranch).')
        parser.add_argument('--to', dest='to_id', required=True,
                            help='New GolfCourseAPI slug (e.g. 8mcwprkp).')
        parser.add_argument('--include-combos', action='store_true',
                            help='Also un-curate combo tees (for a full replace).')
        parser.add_argument('--apply', action='store_true',
                            help='Commit (default is a dry-run that rolls back).')

    def handle(self, *args, **opts):
        from core.models import CatalogCourse, Course

        old_id, new_id = opts['from_id'], opts['to_id']
        apply = opts['apply']
        banner = 'APPLY' if apply else 'DRY-RUN (rolls back)'
        self.stdout.write(self.style.MIGRATE_HEADING(
            f'\n=== relink_catalog_course {old_id} → {new_id} — {banner} ===\n'))
        try:
            with transaction.atomic():
                cc = CatalogCourse.objects.filter(golf_api_id=old_id).first()
                if cc is None:
                    if CatalogCourse.objects.filter(golf_api_id=new_id).exists():
                        self.stdout.write(f'{old_id} not found but {new_id} exists — already relinked; re-importing.')
                    else:
                        raise CommandError(
                            f'No catalog course with golf_api_id={old_id} (and {new_id} '
                            f'not present). Import it fresh from the app instead.')
                else:
                    clash = CatalogCourse.objects.filter(golf_api_id=new_id).exclude(pk=cc.pk).first()
                    if clash is not None:
                        raise CommandError(
                            f'{new_id} already used by "{clash.name}" — would collide; aborting.')
                    cc.golf_api_id = new_id
                    cc.save(update_fields=['golf_api_id'])
                    n = Course.objects.filter(golf_api_id=old_id).update(golf_api_id=new_id)
                    self.stdout.write(f'Stamped catalog "{cc.name}" + {n} account course(s): {old_id} → {new_id}')

                self.stdout.write('\n-- uncurate --')
                call_command('uncurate_catalog_tees', golf_api_id=new_id,
                             apply=True, include_combos=opts['include_combos'])
                self.stdout.write('\n-- reimport + propagate --')
                call_command('reimport_catalog_course', golf_api_id=new_id,
                             propagate=True, apply=True)

                if not apply:
                    raise _DryRunRollback
        except _DryRunRollback:
            self.stdout.write(self.style.WARNING(
                '\nDRY-RUN complete — rolled back. Re-run with --apply to commit.'))
            return
        self.stdout.write(self.style.SUCCESS('\nrelink complete.'))
