"""
games/migrations/0007_irish_rumble_config_low_net_config.py
------------------------------------------------------------
Adds handicap/bet fields to IrishRumbleConfig and creates LowNetRoundConfig.

IrishRumbleConfig changes:
  - handicap_mode (gross / net / strokes_off, default 'net')
  - net_percent   (default 100)
  - bet_unit      (default 1.00)

New model LowNetRoundConfig:
  - round         (OneToOne → tournament.Round)
  - handicap_mode
  - net_percent
  - entry_fee
  - payouts       (JSONField)
"""

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games',      '0006_nassau_update'),
        ('tournament', '0002_round_created_by'),
    ]

    operations = [
        # ── IrishRumbleConfig: add handicap_mode ───────────────────────────
        migrations.AddField(
            model_name='irishrumbleconfig',
            name='handicap_mode',
            field=models.CharField(
                choices=[
                    ('net',         'Net'),
                    ('gross',       'Gross'),
                    ('strokes_off', 'Strokes Off Low'),
                ],
                default='net',
                max_length=20,
            ),
        ),

        # ── IrishRumbleConfig: add net_percent ─────────────────────────────
        migrations.AddField(
            model_name='irishrumbleconfig',
            name='net_percent',
            field=models.PositiveSmallIntegerField(
                default=100,
                help_text="Percentage of playing handicap applied when handicap_mode='net'.",
            ),
        ),

        # ── IrishRumbleConfig: add bet_unit ────────────────────────────────
        migrations.AddField(
            model_name='irishrumbleconfig',
            name='bet_unit',
            field=models.DecimalField(
                decimal_places=2,
                default=1.0,
                help_text='Dollar value of the Irish Rumble bet (winner-take-all).',
                max_digits=6,
            ),
        ),

        # ── New model: LowNetRoundConfig ───────────────────────────────────
        migrations.CreateModel(
            name='LowNetRoundConfig',
            fields=[
                (
                    'id',
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name='ID',
                    ),
                ),
                (
                    'handicap_mode',
                    models.CharField(
                        choices=[
                            ('net',         'Net'),
                            ('gross',       'Gross'),
                            ('strokes_off', 'Strokes Off Low'),
                        ],
                        default='net',
                        max_length=20,
                    ),
                ),
                (
                    'net_percent',
                    models.PositiveSmallIntegerField(
                        default=100,
                        help_text="Percentage of playing handicap applied when handicap_mode='net'.",
                    ),
                ),
                (
                    'entry_fee',
                    models.DecimalField(
                        decimal_places=2,
                        default=0.0,
                        help_text='Entry fee per player.',
                        max_digits=8,
                    ),
                ),
                (
                    'payouts',
                    models.JSONField(
                        default=list,
                        help_text=(
                            "Payout per finishing place. "
                            "Example: [{'place': 1, 'amount': 60.00}, "
                            "{'place': 2, 'amount': 30.00}]"
                        ),
                    ),
                ),
                (
                    'round',
                    models.OneToOneField(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name='low_net_config',
                        to='tournament.round',
                    ),
                ),
            ],
        ),
    ]
