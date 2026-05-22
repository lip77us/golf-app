"""
Add account FK to Player and Course, then backfill every existing
row to the first Account (Golden Glove on the dev DB; whatever
account name was used in `swap_to_accounts` on production).

The field is added nullable, the data migration fills it in, and a
final AlterField tightens it to NOT NULL — all in one migration so
the column never sits in a "partial" state outside the transaction.
"""

import django.db.models.deletion
from django.db import migrations, models


def backfill_account(apps, schema_editor):
    Account = apps.get_model('accounts', 'Account')
    Player  = apps.get_model('core',     'Player')
    Course  = apps.get_model('core',     'Course')

    account = Account.objects.order_by('id').first()
    if account is None:
        # No accounts yet — nothing to backfill.  Happens on a
        # truly fresh DB; the AlterField step below would normally
        # fail on NOT NULL if there were any pre-existing rows, but
        # there aren't.
        return

    Player.objects.filter(account__isnull=True).update(account=account)
    Course.objects.filter(account__isnull=True).update(account=account)


def reverse_noop(apps, schema_editor):
    # Backwards migration just nulls the FKs out; AddField's reverse
    # will then drop the column entirely.
    Player = apps.get_model('core', 'Player')
    Course = apps.get_model('core', 'Course')
    Player.objects.update(account=None)
    Course.objects.update(account=None)


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0001_initial'),
        ('core',     '0003_player_short_name'),
    ]

    operations = [
        migrations.AddField(
            model_name='player',
            name='account',
            field=models.ForeignKey(
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='players',
                to='accounts.account',
                help_text='Tenant this player belongs to.',
            ),
        ),
        migrations.AddField(
            model_name='course',
            name='account',
            field=models.ForeignKey(
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='courses',
                to='accounts.account',
                help_text='Tenant this course belongs to.',
            ),
        ),
        migrations.RunPython(backfill_account, reverse_noop),
        migrations.AlterField(
            model_name='player',
            name='account',
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name='players',
                to='accounts.account',
                help_text='Tenant this player belongs to.',
            ),
        ),
        migrations.AlterField(
            model_name='course',
            name='account',
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name='courses',
                to='accounts.account',
                help_text='Tenant this course belongs to.',
            ),
        ),
    ]
