"""
Add the Points 5-3-1 casual-round game: a per-hole points contest for
exactly three real players.  Scoring is 5/3/1 to 1st/2nd/3rd on each
hole with ties split evenly so every hole pays exactly 9 points.

This migration adds the two backing tables — Points531Game (one row per
foursome) and Points531PlayerHoleResult (one row per game-player-hole) —
along with the POINTS_531 choice on core.GameType.  No data migration is
needed: the new tables start empty, and the active_games list on
existing rounds is unaffected (Points 5-3-1 is picked at round-creation
time in the casual-round flow).
"""

import django.core.validators
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core',  '0003_player_short_name'),
        ('games', '0002_sixes_handicap_mode'),
        ('tournament', '0001_initial'),
    ]

    operations = [
        migrations.CreateModel(
            name='Points531Game',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True,
                                        serialize=False, verbose_name='ID')),
                ('status', models.CharField(
                    choices=[('pending', 'Pending'),
                             ('in_progress', 'In Progress'),
                             ('complete', 'Complete'),
                             ('halved', 'Halved')],
                    default='pending',
                    max_length=20)),
                ('handicap_mode', models.CharField(
                    choices=[('net', 'Net'),
                             ('gross', 'Gross'),
                             ('strokes_off', 'Strokes Off Low')],
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
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('foursome', models.OneToOneField(
                    on_delete=models.deletion.CASCADE,
                    related_name='points_531_game',
                    to='tournament.foursome')),
            ],
        ),
        migrations.CreateModel(
            name='Points531PlayerHoleResult',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True,
                                        serialize=False, verbose_name='ID')),
                ('hole_number', models.PositiveSmallIntegerField(
                    validators=[
                        django.core.validators.MinValueValidator(1),
                        django.core.validators.MaxValueValidator(18),
                    ])),
                ('net_score', models.SmallIntegerField(
                    help_text='The score used for ranking (net/gross/'
                              'SO-adjusted, per game.handicap_mode).')),
                ('points_awarded', models.DecimalField(
                    decimal_places=2, max_digits=4,
                    help_text='Per-hole points — 5/3/1 by rank, tie-split '
                              'so sum per hole is always 9.')),
                ('game', models.ForeignKey(
                    on_delete=models.deletion.CASCADE,
                    related_name='hole_results',
                    to='games.points531game')),
                ('player', models.ForeignKey(
                    on_delete=models.deletion.CASCADE,
                    related_name='points_531_hole_results',
                    to='core.player')),
            ],
            options={
                'ordering': ['hole_number', '-points_awarded'],
                'unique_together': {('game', 'player', 'hole_number')},
            },
        ),
    ]
