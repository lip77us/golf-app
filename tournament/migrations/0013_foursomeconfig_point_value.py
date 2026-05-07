"""
Add per-foursome point_value to RyderCupFoursomeConfig.

This lets organisers set different cup point weights for different game
types within the same round (e.g. Fourball = 2 pts, Singles = 1 pt).
Existing rows get the neutral default of 1.00.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0012_add_missing_teamtournament_columns'),
    ]

    operations = [
        migrations.AddField(
            model_name='rydercupfoursomeconfig',
            name='point_value',
            field=models.DecimalField(
                decimal_places=2,
                default='1.00',
                help_text=(
                    'Cup points awarded per match/segment win for this group. '
                    'Overrides the round-level nassau_point_value.'
                ),
                max_digits=5,
            ),
        ),
    ]
