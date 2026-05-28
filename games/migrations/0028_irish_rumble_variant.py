# Hand-written migration: adds variant + custom_balls fields to
# IrishRumbleConfig to support the four named variants (classic,
# arizona_shuffle, shuffle, custom).

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0027_matchplaybracket_handicap_mode_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='irishrumbleconfig',
            name='variant',
            field=models.CharField(
                max_length=20,
                choices=[
                    ('classic',         'Classic'),
                    ('arizona_shuffle', 'Arizona Shuffle'),
                    ('shuffle',         'Shuffle (par-based)'),
                    ('custom',          'Custom (per-hole)'),
                ],
                default='classic',
                help_text=(
                    'Scoring pattern.  The segments JSON below is derived '
                    'from variant + course par at setup.'
                ),
            ),
        ),
        migrations.AddField(
            model_name='irishrumbleconfig',
            name='custom_balls',
            field=models.JSONField(
                null=True, blank=True,
                help_text=(
                    'Custom variant: 18-element list of per-hole balls-to-count '
                    '(1-4 each).  Null for named variants.'
                ),
            ),
        ),
    ]
