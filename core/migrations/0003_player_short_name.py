"""
Add Player.short_name — a compact (≤ 5 char) display label used wherever
the UI would otherwise compute initials on the fly (e.g. Sixes team
abbreviations).

The column is added with blank=True.  A data migration backfills every
existing Player row by computing its initials-of-first-two-words
(matching the mobile app's legacy _initials() helper), so every player
ends up with a sensible default without any manual admin work.  Users
can still override later from the player form.
"""

from django.db import migrations, models


def _default_short_name_for(name: str) -> str:
    """Duplicated from Player.default_short_name_for so the data migration
    stays self-contained (migrations should not import from models that
    might change shape over time)."""
    parts = (name or '').strip().split()
    initials = ''.join(p[0].upper() for p in parts[:2] if p)
    return initials[:5]


def backfill_short_name(apps, schema_editor):
    Player = apps.get_model('core', 'Player')
    for p in Player.objects.all():
        if not p.short_name:
            p.short_name = _default_short_name_for(p.name)
            p.save(update_fields=['short_name'])


def noop_reverse(apps, schema_editor):
    # On reversal the column is dropped by the schema op that follows,
    # so there is nothing to undo at the data layer.
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0002_player_sex_tee_sex_priority'),
    ]

    operations = [
        migrations.AddField(
            model_name='player',
            name='short_name',
            field=models.CharField(
                blank=True,
                help_text='Short display label (max 5 chars). Auto-defaults '
                          'to initials of first two name words when left blank.',
                max_length=5,
            ),
        ),
        migrations.RunPython(backfill_short_name, noop_reverse),
    ]
