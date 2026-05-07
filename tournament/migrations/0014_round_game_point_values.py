"""
Add game_point_values JSONField to Round.

Stores cup point values per game type (e.g. {"nassau": 1.0, "singles": 2.0})
set at wizard creation time and applied automatically during CupRoundSetupScreen.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0013_foursomeconfig_point_value'),
    ]

    operations = [
        migrations.AddField(
            model_name='round',
            name='game_point_values',
            field=models.JSONField(
                blank=True,
                default=dict,
                help_text=(
                    'Cup point value per game type, e.g. '
                    '{"nassau": 1.0, "singles": 2.0}. '
                    'Used only for Cup rounds.'
                ),
            ),
        ),
    ]
