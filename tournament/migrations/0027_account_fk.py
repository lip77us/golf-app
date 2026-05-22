"""
Add account FK to Tournament and Round, backfill existing rows to
the first Account, and tighten to NOT NULL.

For Rounds that belong to a Tournament, account is inherited from the
parent Tournament; standalone (casual) Rounds get the single
bootstrap account.  In the dev DB right after `swap_to_accounts`
every tournament and round belongs to the one Golden Glove account
so the two paths produce the same answer — but the inheritance is
still applied so we honour the real relationship and future
multi-account scenarios just work.
"""

import django.db.models.deletion
from django.db import migrations, models


def backfill_account(apps, schema_editor):
    Account    = apps.get_model('accounts',   'Account')
    Tournament = apps.get_model('tournament', 'Tournament')
    Round      = apps.get_model('tournament', 'Round')

    account = Account.objects.order_by('id').first()
    if account is None:
        return

    # All existing tournaments belong to the bootstrap account.
    Tournament.objects.filter(account__isnull=True).update(account=account)

    # Tournament rounds inherit account from their parent; casual
    # rounds (tournament__isnull=True) fall through to the same
    # bootstrap account.
    for r in Round.objects.filter(account__isnull=True).select_related('tournament'):
        r.account = r.tournament.account if r.tournament_id else account
        r.save(update_fields=['account'])


def reverse_noop(apps, schema_editor):
    Tournament = apps.get_model('tournament', 'Tournament')
    Round      = apps.get_model('tournament', 'Round')
    Tournament.objects.update(account=None)
    Round.objects.update(account=None)


class Migration(migrations.Migration):

    dependencies = [
        ('accounts',   '0001_initial'),
        ('tournament', '0026_round_watch_token'),
    ]

    operations = [
        migrations.AddField(
            model_name='tournament',
            name='account',
            field=models.ForeignKey(
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='tournaments',
                to='accounts.account',
                help_text='Tenant this tournament belongs to.',
            ),
        ),
        migrations.AddField(
            model_name='round',
            name='account',
            field=models.ForeignKey(
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='rounds',
                to='accounts.account',
                help_text='Tenant this round belongs to.',
            ),
        ),
        migrations.RunPython(backfill_account, reverse_noop),
        migrations.AlterField(
            model_name='tournament',
            name='account',
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name='tournaments',
                to='accounts.account',
                help_text='Tenant this tournament belongs to.',
            ),
        ),
        migrations.AlterField(
            model_name='round',
            name='account',
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name='rounds',
                to='accounts.account',
                help_text='Tenant this round belongs to.',
            ),
        ),
    ]
