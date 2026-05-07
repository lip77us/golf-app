# Generated manually — Ryder Cup / Team Tournament models

import django.core.validators
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0003_player_short_name'),
        ('tournament', '0008_alter_foursomemembership_phantom_algorithm_and_more'),
    ]

    operations = [

        # ── TeamTournament ─────────────────────────────────────────────────
        migrations.CreateModel(
            name='TeamTournament',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('cup_name', models.CharField(
                    default='Ryder Cup',
                    max_length=100,
                    help_text="Display name for the team competition (e.g. 'Bandon Cup'). Shown in app header.",
                )),
                ('players_per_team', models.PositiveSmallIntegerField(
                    default=6,
                    help_text='Target roster size per team. Advisory — the app does not prevent uneven rosters.',
                )),
                ('draft_complete', models.BooleanField(
                    default=False,
                    help_text='Set True to lock team rosters before play begins. The UI should block player moves after this.',
                )),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('tournament', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='team_tournament',
                    to='tournament.tournament',
                )),
            ],
        ),

        # ── TournamentTeam ─────────────────────────────────────────────────
        migrations.CreateModel(
            name='TournamentTeam',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=100)),
                ('team_number', models.PositiveSmallIntegerField()),
                ('colour', models.CharField(
                    blank=True, max_length=50,
                    help_text='Display colour name shown in the mobile UI.',
                )),
                ('short_code', models.CharField(
                    blank=True, max_length=5,
                    help_text='Up to 5-char abbreviation for scorecards (e.g. \'USA\').',
                )),
                ('players', models.ManyToManyField(
                    blank=True,
                    related_name='tournament_teams',
                    to='core.player',
                )),
                ('tournament', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='teams',
                    to='tournament.teamtournament',
                )),
            ],
            options={
                'ordering': ['team_number'],
            },
        ),
        migrations.AddConstraint(
            model_name='tournamentteam',
            constraint=models.UniqueConstraint(
                fields=['tournament', 'team_number'],
                name='unique_team_number_per_tournament',
            ),
        ),

        # ── RyderCupRoundConfig ────────────────────────────────────────────
        migrations.CreateModel(
            name='RyderCupRoundConfig',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('nassau_point_value', models.DecimalField(
                    decimal_places=2, default='1.00', max_digits=5,
                    help_text='Ryder Cup points awarded per Nassau-segment win. A halved segment gives each team half this value.',
                )),
                ('point_multiplier', models.DecimalField(
                    decimal_places=2, default='1.00', max_digits=5,
                    validators=[django.core.validators.MinValueValidator('0.01')],
                    help_text='Multiplier applied to all points in this round.',
                )),
                ('notes', models.TextField(blank=True)),
                ('round', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='ryder_cup_config',
                    to='tournament.round',
                )),
                ('tournament', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='round_configs',
                    to='tournament.teamtournament',
                )),
            ],
        ),

        # ── RyderCupFoursomeConfig ─────────────────────────────────────────
        migrations.CreateModel(
            name='RyderCupFoursomeConfig',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('game_type', models.CharField(
                    max_length=30,
                    choices=[
                        ('irish_rumble', 'Irish Rumble'),
                        ('nassau', 'Nassau'),
                        ('sixes', "Six's"),
                        ('pink_ball', 'Pink Ball'),
                        ('scramble', 'Scramble'),
                        ('match_play', 'Match Play'),
                        ('stableford', 'Stableford'),
                        ('skins', 'Skins'),
                        ('low_net_round', 'Low Net (Round)'),
                        ('low_net', 'Low Net Championship'),
                        ('points_531', 'Points 5-3-1'),
                        ('three_person_match', 'Three-Person Match'),
                        ('quota_nassau', 'Quota Nassau'),
                    ],
                    help_text='Game this foursome plays. Must be a GameType value supported by the app.',
                )),
                ('foursome', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='ryder_cup_foursome_config',
                    to='tournament.foursome',
                )),
                ('round_config', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='foursome_configs',
                    to='tournament.rydercuproundconfig',
                )),
                ('team1', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.PROTECT,
                    related_name='foursome_configs_as_t1',
                    to='tournament.tournamentteam',
                )),
                ('team2', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.PROTECT,
                    related_name='foursome_configs_as_t2',
                    to='tournament.tournamentteam',
                )),
            ],
        ),

        # ── RyderCupIrishRumblePairing ─────────────────────────────────────
        migrations.CreateModel(
            name='RyderCupIrishRumblePairing',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('front9_result', models.CharField(
                    blank=True, max_length=10, null=True,
                    choices=[('team1', 'Team 1'), ('team2', 'Team 2'), ('halved', 'Halved')],
                    help_text="'team1'=team_a won the front 9.",
                )),
                ('back9_result', models.CharField(
                    blank=True, max_length=10, null=True,
                    choices=[('team1', 'Team 1'), ('team2', 'Team 2'), ('halved', 'Halved')],
                )),
                ('overall_result', models.CharField(
                    blank=True, max_length=10, null=True,
                    choices=[('team1', 'Team 1'), ('team2', 'Team 2'), ('halved', 'Halved')],
                )),
                ('round_config', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='irish_rumble_pairings',
                    to='tournament.rydercuproundconfig',
                )),
                ('foursome_a', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='ryder_cup_rumble_as_a',
                    to='tournament.foursome',
                )),
                ('foursome_b', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='ryder_cup_rumble_as_b',
                    to='tournament.foursome',
                )),
                ('team_a', models.ForeignKey(
                    on_delete=django.db.models.deletion.PROTECT,
                    related_name='rumble_pairings_as_a',
                    to='tournament.tournamentteam',
                )),
                ('team_b', models.ForeignKey(
                    on_delete=django.db.models.deletion.PROTECT,
                    related_name='rumble_pairings_as_b',
                    to='tournament.tournamentteam',
                )),
            ],
        ),

        # ── RyderCupMatchPoints ────────────────────────────────────────────
        migrations.CreateModel(
            name='RyderCupMatchPoints',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('segment', models.CharField(
                    max_length=10,
                    choices=[('front9', 'Front 9'), ('back9', 'Back 9'), ('overall', 'Overall 18')],
                )),
                ('game_type', models.CharField(max_length=30)),
                ('result', models.CharField(
                    blank=True, max_length=10, null=True,
                    choices=[('team1', 'Team 1'), ('team2', 'Team 2'), ('halved', 'Halved')],
                )),
                ('team1_points', models.DecimalField(decimal_places=2, default=0, max_digits=6)),
                ('team2_points', models.DecimalField(decimal_places=2, default=0, max_digits=6)),
                ('round_config', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='match_points',
                    to='tournament.rydercuproundconfig',
                )),
                ('team1', models.ForeignKey(
                    on_delete=django.db.models.deletion.PROTECT,
                    related_name='ryder_points_as_t1',
                    to='tournament.tournamentteam',
                )),
                ('team2', models.ForeignKey(
                    on_delete=django.db.models.deletion.PROTECT,
                    related_name='ryder_points_as_t2',
                    to='tournament.tournamentteam',
                )),
                ('foursome', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='ryder_cup_points',
                    to='tournament.foursome',
                )),
                ('irish_rumble_pairing', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='match_points',
                    to='tournament.rydercupirishrumblepairing',
                )),
                ('player1', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='ryder_points_as_p1',
                    to='core.player',
                )),
                ('player2', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='ryder_points_as_p2',
                    to='core.player',
                )),
            ],
            options={
                'ordering': ['round_config', 'game_type', 'segment'],
            },
        ),
    ]
