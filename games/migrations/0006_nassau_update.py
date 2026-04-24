"""
games/migrations/0006_nassau_update.py
---------------------------------------
Upgrades NassauGame and NassauPress to support:
  - handicap_mode / net_percent (net / gross / strokes_off)
  - press_mode (none / manual / auto / both)
  - press_unit (explicit dollar amount per press, replacing press_pct fraction)
  - NassauPress.press_type ('auto' | 'manual')
  - NassauHoleScore.overall_up_after (running 18-hole margin)
"""

import django.core.validators
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0005_alter_points531game_id_and_more'),
    ]

    operations = [
        # ── NassauGame: add new fields ────────────────────────────────────────
        migrations.AddField(
            model_name='nassaugame',
            name='handicap_mode',
            field=models.CharField(
                choices=[('net', 'Net'), ('gross', 'Gross'), ('strokes_off', 'Strokes Off Low')],
                default='net',
                max_length=20,
                help_text="How individual scores are adjusted before best-ball comparison.",
            ),
        ),
        migrations.AddField(
            model_name='nassaugame',
            name='net_percent',
            field=models.PositiveSmallIntegerField(
                default=100,
                validators=[
                    django.core.validators.MinValueValidator(0),
                    django.core.validators.MaxValueValidator(200),
                ],
                help_text="Percentage of playing handicap applied when handicap_mode='net'.",
            ),
        ),
        migrations.AddField(
            model_name='nassaugame',
            name='press_mode',
            field=models.CharField(
                choices=[
                    ('none',   'No presses'),
                    ('manual', 'Manual — losing team calls it, winning team must accept'),
                    ('auto',   'Auto at 2-down'),
                    ('both',   'Manual + auto at 2-down'),
                ],
                default='none',
                max_length=10,
            ),
        ),
        migrations.AddField(
            model_name='nassaugame',
            name='press_unit',
            field=models.DecimalField(
                decimal_places=2,
                default='0.00',
                max_digits=8,
                help_text="Dollar amount per press bet (separate from Round.bet_unit).",
            ),
        ),
        # ── NassauGame: remove the old press_pct fraction field ───────────────
        migrations.RemoveField(
            model_name='nassaugame',
            name='press_pct',
        ),
        # ── NassauHoleScore: add overall running margin ───────────────────────
        migrations.AddField(
            model_name='nassauholescore',
            name='overall_up_after',
            field=models.SmallIntegerField(
                null=True,
                blank=True,
                help_text="Running overall margin after this hole (all 18).",
            ),
        ),
        # ── NassauPress: add press_type ───────────────────────────────────────
        migrations.AddField(
            model_name='nassaupress',
            name='press_type',
            field=models.CharField(
                choices=[('manual', 'Manual'), ('auto', 'Auto')],
                default='auto',
                max_length=10,
            ),
        ),
    ]
