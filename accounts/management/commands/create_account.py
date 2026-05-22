"""
accounts/management/commands/create_account.py
----------------------------------------------
Bootstrap a new Account + its first admin user from the CLI.

Useful for spinning up additional tenants on a dev DB without
clicking through /admin/ — and for demoing multi-tenant isolation
end-to-end against the mobile app.

Usage
-----
    poetry run python manage.py create_account "Test Group" \\
        --admin-username ryanboss \\
        --admin-password "first-login-password" \\
        --admin-email ryan@example.com

Idempotent on the Account row (re-runs with the same name will
attach the new admin to the existing Account).  Refuses to create
a second user with a duplicate username inside the same Account.
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from accounts.models import Account


User = get_user_model()


class Command(BaseCommand):
    help = (
        'Create a new Account and a starter admin user in one shot. '
        'Use this for adding extra tenants on a dev DB or for the '
        'first-deploy bootstrap on a new server.'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            'account_name',
            help='Display name for the new account (case-insensitive '
                 'unique, e.g. "Test Group" or "Bandon Saturday").',
        )
        parser.add_argument(
            '--admin-username',
            required=True,
            help='Username of the bootstrap admin inside this account.',
        )
        parser.add_argument(
            '--admin-password',
            required=True,
            help='Initial password for the bootstrap admin.  Tell the '
                 'user to change it on first login.',
        )
        parser.add_argument(
            '--admin-email',
            default='',
            help='Optional email for the bootstrap admin.',
        )
        parser.add_argument(
            '--admin-first-name',
            default='',
        )
        parser.add_argument(
            '--admin-last-name',
            default='',
        )

    @transaction.atomic
    def handle(self, *, account_name, admin_username,
               admin_password, admin_email,
               admin_first_name, admin_last_name, **opts):
        account_name = account_name.strip()
        admin_username = admin_username.strip()
        if len(admin_password) < 8:
            raise CommandError(
                '--admin-password must be at least 8 characters.'
            )

        # Reuse the account if one with the same (case-insensitive)
        # name already exists — saves the user from having to clean
        # up when iterating on the bootstrap.
        account, created = Account.objects.get_or_create(
            name__iexact=account_name,
            defaults={'name': account_name},
        )
        if created:
            self.stdout.write(self.style.SUCCESS(
                f'Created Account "{account.name}" (id={account.id}).'
            ))
        else:
            self.stdout.write(
                f'Account "{account.name}" (id={account.id}) already '
                f'exists; reusing.'
            )

        if User.objects.filter(
            account=account, username__iexact=admin_username,
        ).exists():
            raise CommandError(
                f'User "{admin_username}" already exists in account '
                f'"{account.name}".  Pick another username or run '
                '`manage.py changepassword` on the existing user.'
            )

        user = User.objects.create_user(
            account=account,
            username=admin_username,
            password=admin_password,
            email=admin_email,
            first_name=admin_first_name,
            last_name=admin_last_name,
        )
        user.is_account_admin = True
        user.save(update_fields=['is_account_admin'])

        self.stdout.write(self.style.SUCCESS(
            f'\nCreated admin user "{user.username}" (id={user.id}) in '
            f'account "{account.name}" with is_account_admin=True.'
        ))
        self.stdout.write(
            f'\nLog in from the mobile app with:\n'
            f'  Account:  {account.name}\n'
            f'  Username: {user.username}\n'
            f'  Password: (the one you just supplied)\n'
        )
