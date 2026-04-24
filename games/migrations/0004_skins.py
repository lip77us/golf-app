"""
Add the Skins casual-round game: a per-hole individual contest for 2–4
real players with optional carryover and optional junk skins.

Three new tables:
  skins_game              — one row per Foursome (game config)
  skins_hole_result       — one row per scored hole (calculator output)
  skins_player_hole_result— one row per (player, hole) for junk counts
                            (written by the junk-entry endpoint, not the
                            calculator).

No data migration needed: existing rounds are unaffected and the
active_games list controls which games are active.
"""

import django.core.validators
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core',       '0003_player_short_name'),
        ('games',      '0003_points_531'),
        ('tournament', '0001_initial'),
    ]

    operations = [
        # ---- SkinsGame -------------------------------------------------------
        migrations.CreateModel(
            name='SkinsGame',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID')),
                ('status', models.CharField(
                    choices=[
                        ('pending',     'Pending'),
                        ('in_progress', 'In Progress'),
                        ('complete',    'Complete'),
                        ('halved',      'Halved'),
                    ],
                    default='pending',
                    max_length=20)),
                ('handicap_mode', models.CharField(
                    choices=[
                        ('net',         'Net'),
                        ('gross',       'Gross'),
                        ('strokes_off', 'Strokes Off Low'),
                    ],
                    default='net',
                    help_text='How per-hole scores are adjusted for ranking.',
                    max_length=20)),
                ('net_percent', models.PositiveSmallIntegerField(
                    default=100,
                    help_text="Percentage of playing handicap applied when "
                              "handicap_mode='net'.",
                    validators=[
                        django.core.validators.MinValueValidator(0),
                        django.core.validators.MaxValueValidator(200),
                    ])),
                ('carryover', models.BooleanField(
                    default=True,
                    help_text='If True a tied hole carries its pot to the '
                              'next hole; if False the tied skin is voided.')),
                ('allow_junk', models.BooleanField(
                    default=False,
                    help_text='If True the entry screen shows a per-player '
                              'junk-skin counter (birdies, sandies, etc.).')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('foursome', models.OneToOneField(
                    on_delete=models.deletion.CASCADE,
                    related_name='skins_game',
                    to='tournament.foursome')),
            ],
        ),

        # ---- SkinsHoleResult ------------------------------------------------
        migrations.CreateModel(
            name='SkinsHoleResult',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID')),
                ('hole_number', models.PositiveSmallIntegerField(
                    validators=[
                        django.core.validators.MinValueValidator(1),
                        django.core.validators.MaxValueValidator(18),
                    ])),
                ('skins_value', models.PositiveSmallIntegerField(default=1)),
                ('is_carry',    models.BooleanField(default=False)),
                ('game', models.ForeignKey(
                    on_delete=models.deletion.CASCADE,
                    related_name='hole_results',
                    to='games.skinsgame')),
                ('winner', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=models.deletion.SET_NULL,
                    related_name='skins_holes_won',
                    to='core.player')),
            ],
            options={
                'ordering': ['hole_number'],
                'unique_together': {('game', 'hole_number')},
            },
        ),

        # ---- SkinsPlayerHoleResult ------------------------------------------
        migrations.CreateModel(
            name='SkinsPlayerHoleResult',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID')),
                ('hole_number', models.PositiveSmallIntegerField(
                    validators=[
                        django.core.validators.MinValueValidator(1),
                        django.core.validators.MaxValueValidator(18),
                    ])),
                ('junk_count', models.PositiveSmallIntegerField(
                    default=0,
                    help_text='Junk skins (birdies, sandies, etc.) earned '
                              'by this player on this hole.')),
                ('game', models.ForeignKey(
                    on_delete=models.deletion.CASCADE,
                    related_name='junk_results',
                    to='games.skinsgame')),
                ('player', models.ForeignKey(
                    on_delete=models.deletion.CASCADE,
                    related_name='skins_junk_results',
                    to='core.player')),
            ],
            options={
                'ordering': ['hole_number', 'player_id'],
                'unique_together': {('game', 'player', 'hole_number')},
            },
        ),
    ]
