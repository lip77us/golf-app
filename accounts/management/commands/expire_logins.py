"""
expire_logins — invalidate auth tokens so users must re-authenticate.

Used at the phone-only cutover: password login is deactivated, so legacy
password accounts (no phone) should be forced to re-authenticate via phone.

By default this purges ONLY tokens for users WITHOUT a phone (the legacy
password accounts), leaving phone-login sessions intact. Pass --all to purge
everyone.

    python manage.py expire_logins          # legacy/password-only sessions
    python manage.py expire_logins --all    # every session (forces all re-auth)

Safe to run against production (only deletes auth tokens; no account/user data).
Affected users simply sign in again with their phone number.
"""
from django.core.management.base import BaseCommand
from rest_framework.authtoken.models import Token


class Command(BaseCommand):
    help = ("Invalidate auth tokens so users re-authenticate (legacy/password-"
            "only by default; --all for everyone).")

    def add_arguments(self, parser):
        parser.add_argument(
            '--all', action='store_true',
            help='Purge ALL sessions, including phone-login users.',
        )

    def handle(self, *args, **opts):
        qs = Token.objects.all()
        if not opts['all']:
            # Legacy/password-only accounts have no phone on the User row.
            qs = qs.filter(user__phone__isnull=True)
        count = qs.count()
        qs.delete()
        scope = 'ALL' if opts['all'] else 'password-only (no phone)'
        self.stdout.write(self.style.SUCCESS(
            f'Expired {count} session token(s) [{scope}]. '
            'Affected users must sign in again with their phone number.'
        ))
