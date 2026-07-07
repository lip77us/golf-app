"""
management command: import_genius_roster
----------------------------------------
Import a **Golf Genius roster export** (.xlsx or .csv) into an account's
``Player`` roster.  Matches each row to an existing golfer by phone (falling
back to GHIN), updating their index + GHIN, or creates a new login-less golfer.

Dry-run by DEFAULT — prints the diff and writes nothing.  Add ``--apply`` to
commit.

Usage
-----
    python manage.py import_genius_roster ~/Downloads/roster.xlsx --account "Tilden"
    python manage.py import_genius_roster ~/Downloads/roster.xlsx --account "Tilden" --apply

``--account`` matches an Account by a case-insensitive name substring (must
resolve to exactly one).  Use ``--account-id`` to target by primary key.

The import logic lives in ``services/genius_import.py`` (shared with the future
TD-facing API endpoint) — this command is just a CLI driver.
"""

from pathlib import Path

from django.core.management.base import BaseCommand, CommandError

from accounts.models import Account
from services import genius_import as gi


class Command(BaseCommand):
    help = "Import a Golf Genius roster export into an account's roster."

    def add_arguments(self, parser):
        parser.add_argument('path', help='Path to the .xlsx or .csv export.')
        parser.add_argument('--account', help='Account name (case-insensitive substring).')
        parser.add_argument('--account-id', type=int, help='Account primary key.')
        parser.add_argument('--apply', action='store_true',
                            help='Commit the import (default is a dry-run preview).')
        parser.add_argument('--limit-preview', type=int, default=15,
                            help='Max rows to list per bucket in the preview.')

    def handle(self, *args, **opts):
        account = self._resolve_account(opts)
        data = self._read_file(opts['path'])

        rows = gi.read_rows(Path(opts['path']).name, data)
        parsed, _ = gi.parse_rows(rows)
        plan = gi.build_plan(account, parsed)

        self._print_plan(plan, account, opts['limit_preview'])

        if not opts['apply']:
            self.stdout.write(self.style.WARNING(
                '\nDRY RUN — nothing written. Re-run with --apply to commit.'))
            return

        created, updated = gi.apply_plan(account, plan)
        self.stdout.write(self.style.SUCCESS(
            f'\nDone: created {created}, updated {updated} '
            f'(account "{account.name}").'))

    # -- helpers ------------------------------------------------------------

    def _resolve_account(self, opts) -> Account:
        if opts.get('account_id'):
            try:
                return Account.objects.get(pk=opts['account_id'])
            except Account.DoesNotExist:
                raise CommandError(f"No account with id {opts['account_id']}.")
        name = opts.get('account')
        if not name:
            raise CommandError('Specify --account "<name>" or --account-id <pk>.')
        matches = list(Account.objects.filter(name__icontains=name))
        if not matches:
            raise CommandError(f'No account matching "{name}".')
        if len(matches) > 1:
            names = ', '.join(f'"{a.name}"' for a in matches)
            raise CommandError(f'"{name}" is ambiguous — matches: {names}.')
        return matches[0]

    def _read_file(self, path: str) -> bytes:
        p = Path(path).expanduser()
        if not p.exists():
            raise CommandError(f'File not found: {p}')
        return p.read_bytes()

    def _print_plan(self, plan, account, limit):
        s = plan.summary()
        self.stdout.write(
            f'\nImport preview for account "{account.name}":\n'
            f'  create {s["create"]}  ·  update {s["update"]}  ·  '
            f'unchanged {s["unchanged"]}  ·  skipped {s["skipped"]}\n')

        if plan.to_create:
            self.stdout.write(self.style.MIGRATE_HEADING('\nNew golfers:'))
            for r in plan.to_create[:limit]:
                idx = r.index if r.index is not None else '—'
                ghin = f' GHIN {r.ghin}' if r.ghin else ''
                phone = f' {r.phone}' if r.phone else ' (no phone)'
                self.stdout.write(f'  + {r.name}  idx {idx}{ghin}{phone}')
            self._more(plan.to_create, limit)

        if plan.to_update:
            self.stdout.write(self.style.MIGRATE_HEADING('\nUpdates:'))
            for u in plan.to_update[:limit]:
                fields = ', '.join(f'{k}→{v}' for k, v in u.changes.items())
                self.stdout.write(f'  ~ {u.player_name}: {fields}')
            self._more(plan.to_update, limit)

        if plan.skipped:
            self.stdout.write(self.style.MIGRATE_HEADING('\nSkipped:'))
            for sk in plan.skipped[:limit]:
                label = sk.row.name or f'(row {sk.row.line})'
                self.stdout.write(f'  ! {label}: {sk.reason}')
            self._more(plan.skipped, limit)

    def _more(self, items, limit):
        if len(items) > limit:
            self.stdout.write(f'  … and {len(items) - limit} more')
