"""
Add the Three-Person Match tournament game: a hybrid 9-hole 5-3-1 points
phase followed by a 9-hole 1v1 match play between the top two finishers.

Three new tables:
  ThreePersonMatch            — one row per foursome (config + seeding + result)
  ThreePersonMatchP1HoleResult — per-hole, per-player 5-3-1 results (phase 1)
  ThreePersonMatchP2HoleResult — per-hole match play / tiebreak results (phase 2)
"""

import django.core.validators
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core',       '0003_player_short_name'),
        ('games',      '0015_alter_lownetroundconfig_excluded_player_ids'),
        ('tournament', '0001_initial'),
    ]

    operations = [
        migrations.CreateModel(
            name='ThreePersonMatch',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID',
                )),
                ('status', models.CharField(
                    choices=[
                        ('pending',       'Pending'),
                        ('phase1',        'Phase 1 (5-3-1)'),
                        ('tiebreak_3way', 'Tiebreak (3-Way Tie)'),
                        ('tiebreak_23',   'Tiebreak (2nd vs 3rd)'),
                        ('phase2',        'Phase 2 (Match Play)'),
                        ('complete',      'Complete'),
                    ],
                    default='pending',
                    max_length=20,
                )),
                ('handicap_mode', models.CharField(
                    choices=[
                        ('net',         'Net'),
                        ('gross',       'Gross'),
                        ('strokes_off', 'Strokes Off Low'),
                    ],
                    default='net',
                    max_length=20,
                )),
                ('net_percent', models.PositiveSmallIntegerField(
                    default=100,
                    validators=[
                        django.core.validators.MinValueValidator(0),
                        django.core.validators.MaxValueValidator(200),
                    ],
                )),
                ('entry_fee', models.DecimalField(
                    decimal_places=2, default=0.0, max_digits=7,
                    help_text='Per-player entry fee for the prize pool.',
                )),
                ('payout_config', models.JSONField(
                    blank=True, default=dict,
                    help_text=(
                        "Dict of place → dollar amount. "
                        "E.g. {'1st': 48.00, '2nd': 24.00, '3rd': 0.00}"
                    ),
                )),
                ('phase2_start_hole', models.PositiveSmallIntegerField(
                    blank=True, null=True,
                    help_text='First hole of the pure match play phase.',
                )),
                ('phase2_carryover', models.SmallIntegerField(
                    default=0,
                    help_text=(
                        'Best-ball match margin at the end of the '
                        'tiebreak_23 phase (+ve = leader ahead).'
                    ),
                )),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('foursome', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='three_person_match',
                    to='tournament.foursome',
                )),
                ('match_winner', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='three_person_match_wins',
                    to='core.player',
                )),
                ('phase1_leader', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='+',
                    to='core.player',
                    help_text='1st-place finisher after the 5-3-1 phase.',
                )),
                ('phase1_runner_up', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='+',
                    to='core.player',
                    help_text='2nd-place seed entering the match play phase.',
                )),
                ('phase1_tied_a', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='+',
                    to='core.player',
                    help_text='Tied-for-2nd candidate A (only set during tiebreak_23).',
                )),
                ('phase1_tied_b', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='+',
                    to='core.player',
                    help_text='Tied-for-2nd candidate B (only set during tiebreak_23).',
                )),
            ],
        ),

        migrations.CreateModel(
            name='ThreePersonMatchP1HoleResult',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID',
                )),
                ('hole_number', models.PositiveSmallIntegerField(
                    validators=[
                        django.core.validators.MinValueValidator(1),
                        django.core.validators.MaxValueValidator(18),
                    ],
                )),
                ('net_score', models.SmallIntegerField()),
                ('points_awarded', models.DecimalField(
                    decimal_places=2, max_digits=4,
                )),
                ('game', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='phase1_results',
                    to='games.threepersonmatch',
                )),
                ('player', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='tpm_p1_hole_results',
                    to='core.player',
                )),
            ],
            options={
                'ordering': ['hole_number', '-points_awarded'],
                'unique_together': {('game', 'player', 'hole_number')},
            },
        ),

        migrations.CreateModel(
            name='ThreePersonMatchP2HoleResult',
            fields=[
                ('id', models.AutoField(
                    auto_created=True, primary_key=True,
                    serialize=False, verbose_name='ID',
                )),
                ('hole_number', models.PositiveSmallIntegerField(
                    validators=[
                        django.core.validators.MinValueValidator(1),
                        django.core.validators.MaxValueValidator(18),
                    ],
                )),
                ('phase', models.CharField(
                    choices=[('tiebreak', 'Tiebreak'), ('phase2', 'Phase 2')],
                    max_length=10,
                )),
                # Main match (leader vs runner_up / best-ball)
                ('main_leader_net',   models.SmallIntegerField(blank=True, null=True)),
                ('main_opp_net',      models.SmallIntegerField(blank=True, null=True)),
                ('main_leader_wins',  models.BooleanField(blank=True, null=True,
                    help_text='True=leader wins hole, False=opp wins, None=halved.')),
                ('main_margin_after', models.SmallIntegerField(default=0,
                    help_text='Running margin after hole (+ve = leader ahead).')),
                # Tiebreak sub-match (phase1_tied_a vs phase1_tied_b)
                ('tb_a_net',          models.SmallIntegerField(blank=True, null=True)),
                ('tb_b_net',          models.SmallIntegerField(blank=True, null=True)),
                ('tb_a_wins',         models.BooleanField(blank=True, null=True,
                    help_text='True=tied_a wins hole, False=tied_b wins, None=halved.')),
                ('tb_margin_after',   models.SmallIntegerField(default=0,
                    help_text='Sub-match margin after hole (+ve = tied_a ahead).')),
                ('game', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='phase2_results',
                    to='games.threepersonmatch',
                )),
            ],
            options={
                'ordering': ['hole_number'],
                'unique_together': {('game', 'hole_number')},
            },
        ),
    ]
