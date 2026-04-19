# Hand-written migration for adding handicap_mode and net_percent to SixesSegment.
#
# These fields let the person setting up a Sixes match choose whether the
# match is played Net (with an optional percent of full handicap) or Gross.
# A third choice, Strokes Off Low, is already in the enum for a future update
# but is not yet wired through the calculator.

import django.core.validators
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("games", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="sixessegment",
            name="handicap_mode",
            field=models.CharField(
                choices=[
                    ("net", "Net"),
                    ("gross", "Gross"),
                    ("strokes_off", "Strokes Off Low"),
                ],
                default="net",
                help_text="How per-hole scores are adjusted for this match.",
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name="sixessegment",
            name="net_percent",
            field=models.PositiveSmallIntegerField(
                default=100,
                help_text=(
                    "Percentage of playing handicap applied when "
                    "handicap_mode='net'."
                ),
                validators=[
                    django.core.validators.MinValueValidator(0),
                    django.core.validators.MaxValueValidator(200),
                ],
            ),
        ),
    ]
