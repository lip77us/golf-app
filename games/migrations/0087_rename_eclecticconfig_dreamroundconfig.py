"""Eclectic is renamed Dream Round.

**`RenameModel`, not create-and-delete.** `makemigrations` offers the latter
for a renamed model — it cannot tell a rename from one model replaced by
another — and taking it would drop the table with every configured event's
pools, entry fees and payout tables in it.

The stored slug moves in `tournament/0075`, which is also where the enum's
choices are refreshed.
"""
from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0086_roadtripconfig_starting_indexes'),
    ]

    operations = [
        migrations.RenameModel(
            old_name='EclecticConfig',
            new_name='DreamRoundConfig',
        ),
    ]
