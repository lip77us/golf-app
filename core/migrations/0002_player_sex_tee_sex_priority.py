"""
Add Player.sex, Tee.sex, Tee.sort_priority.

Default-tee-selection bug: picking a tee during round setup used to be
alphabetical, so "Red M" and "Red W" sorted before "White" in test data.
The fix is to pick tees by matching Player.sex against Tee.sex (or
unisex tees with Tee.sex=null), then by Tee.sort_priority.

The data migration sets sensible defaults for the tees that already
exist by pattern-matching tee_name (White/Blue/Black/Red M/Red W etc.).
Tees that don't match the heuristic keep the model defaults
(sex=null, sort_priority=100) and can be updated via the admin.
"""

from django.db import migrations, models


def _default_sex_and_priority(tee_name: str):
    """
    Return (sex, priority) for a tee based on its name.

    Convention: LOWER priority = MORE default, so a dropdown sorted by
    priority ASC puts the everyday-play tee at the top.

    Heuristics (most specific → least):
      * "Red W" / "Red Women's" / "Ladies" / ends with " W"  → W, 10  (default women's)
      * "Red M" / ends with " M" / "forward men"             → M, 40  (forward men's)
      * "Championship" / "Tips" / "Pro" / "Black"            → null, 50 (back tees)
      * "Blue" / "Tournament"                                → M, 20  (next up from White)
      * "Gold" / "Senior"                                    → M, 30
      * "White"                                              → M, 10  (default men's)
      * "Red" (bare, no M/W suffix)                          → W, 10  (default women's forward)
    Anything else → (null, 100), leave for manual cleanup via admin.
    """
    n = (tee_name or '').strip().lower()
    if n.endswith(' w') or 'women' in n or 'ladies' in n:
        return 'W', 10
    if n.endswith(' m') or (' men' in f' {n} ' and 'women' not in n):
        return 'M', 40
    if any(k in n for k in ('championship', 'tips', 'pro', 'black')):
        return None, 50
    if any(k in n for k in ('blue', 'tournament')):
        return 'M', 20
    if any(k in n for k in ('gold', 'senior')):
        return 'M', 30
    if 'white' in n:
        return 'M', 10
    if 'red' in n:
        return 'W', 10
    return None, 100


def set_tee_defaults(apps, schema_editor):
    Tee = apps.get_model('core', 'Tee')
    for tee in Tee.objects.all():
        sex, prio = _default_sex_and_priority(tee.tee_name)
        tee.sex = sex
        tee.sort_priority = prio
        tee.save(update_fields=['sex', 'sort_priority'])


def noop_reverse(apps, schema_editor):
    # Nothing to undo on reversal — the columns themselves get dropped
    # by the schema operations above.
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0001_initial'),
    ]

    operations = [
        migrations.AddField(
            model_name='player',
            name='sex',
            field=models.CharField(
                choices=[('M', 'Male'), ('W', 'Female')],
                default='M',
                help_text='Determines the default tee during round setup.',
                max_length=1,
            ),
        ),
        migrations.AddField(
            model_name='tee',
            name='sex',
            field=models.CharField(
                blank=True,
                choices=[('M', 'Male'), ('W', 'Female')],
                help_text='Tee designation. Null for unisex.',
                max_length=1,
                null=True,
            ),
        ),
        migrations.AddField(
            model_name='tee',
            name='sort_priority',
            field=models.PositiveSmallIntegerField(
                default=100,
                help_text='Lower = more default. Used to pick the default '
                          'tee for a player of a given sex.',
            ),
        ),
        migrations.RunPython(set_tee_defaults, noop_reverse),
    ]
