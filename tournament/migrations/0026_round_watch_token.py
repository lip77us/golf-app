# Adds Round.watch_token + back-fills existing rounds with a unique
# short code so the public spectator URL (/watch/<token>/) works for
# the entire history, not only newly-created rounds.

import secrets
import string

from django.db import migrations, models


def _backfill_tokens(apps, schema_editor):
    Round = apps.get_model('tournament', 'Round')
    alphabet = string.ascii_uppercase + '23456789'  # base32-ish, drop 0/1/I/O
    existing = set(
        Round.objects.exclude(watch_token__isnull=True)
                     .values_list('watch_token', flat=True)
    )
    for r in Round.objects.filter(watch_token__isnull=True):
        for _ in range(5):
            candidate = ''.join(secrets.choice(alphabet) for _ in range(8))
            if candidate not in existing:
                existing.add(candidate)
                r.watch_token = candidate
                r.save(update_fields=['watch_token'])
                break


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0025_multi_skins'),
    ]

    operations = [
        migrations.AddField(
            model_name='round',
            name='watch_token',
            field=models.CharField(
                blank=True, null=True, max_length=12, unique=True,
                help_text=(
                    'Random short code used in the public spectator URL: '
                    '/watch/<token>/.'
                ),
            ),
        ),
        migrations.RunPython(_backfill_tokens, migrations.RunPython.noop),
    ]
