"""
games/migrations/0003_sixes_nassau_9918.py
------------------------------------------
• Drops old NassauSegment / NassauTeam / NassauHoleResult (the 6s game
  was incorrectly named Nassau in the original schema).
• Creates SixesSegment / SixesTeam / SixesHoleResult with new fields.
• Creates NassauGame / NassauTeam / NassauHoleScore / NassauPress for the
  actual 9-9-18 Nassau format.

Uses DeleteModel + CreateModel instead of RenameModel to avoid a
PostgreSQL constraint-name collision: RenameModel renames the table but
leaves the M2M unique-constraint name unchanged, causing a duplicate
when the new NassauTeam tries to create an identically-hashed constraint.
"""

from django.db import migrations, models
import django.db.models.deletion


MATCH_STATUS = [
    ('pending',     'Pending'),
    ('in_progress', 'In Progress'),
    ('complete',    'Complete'),
    ('halved',      'Halved'),
]

NASSAU_RESULT = [
    ('team1',  'Team 1'),
    ('team2',  'Team 2'),
    ('halved', 'Halved'),
]

TEAM_SELECT = [
    ('long_drive',   'Long Drive'),
    ('random',       'Random'),
    ('remainder',    'Remainder'),
    ('loser_choice', "Loser's Choice"),
]


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0002_pinkballholeresult_ball_lost_pinkballresult'),
        ('tournament', '0001_initial'),
        ('core', '0001_initial'),
    ]

    operations = [
        # ----------------------------------------------------------------
        # 1. Drop old Nassau* models (they were the 6s game)
        #    Delete in FK order: child → parent
        # ----------------------------------------------------------------
        migrations.DeleteModel('NassauHoleResult'),
        migrations.DeleteModel('NassauTeam'),
        migrations.DeleteModel('NassauSegment'),

        # ----------------------------------------------------------------
        # 2. Create SixesSegment
        # ----------------------------------------------------------------
        migrations.CreateModel(
            name='SixesSegment',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('segment_number', models.PositiveSmallIntegerField()),
                ('start_hole',     models.PositiveSmallIntegerField()),
                ('end_hole',       models.PositiveSmallIntegerField()),
                ('status',         models.CharField(max_length=20, choices=MATCH_STATUS,
                                                    default='pending')),
                ('is_extra',       models.BooleanField(
                    default=False,
                    help_text='True for the 4th match created from leftover holes after an early finish.',
                )),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('foursome', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='sixes_segments',
                    to='tournament.foursome',
                )),
            ],
            options={
                'ordering': ['segment_number', 'start_hole'],
            },
        ),

        # ----------------------------------------------------------------
        # 3. Create SixesTeam
        # ----------------------------------------------------------------
        migrations.CreateModel(
            name='SixesTeam',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('team_number',        models.PositiveSmallIntegerField()),
                ('team_select_method', models.CharField(max_length=20, choices=TEAM_SELECT)),
                ('is_winner',          models.BooleanField(default=False)),
                ('players', models.ManyToManyField(related_name='sixes_teams',
                                                   to='core.player')),
                ('segment', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='teams',
                    to='games.sixessegment',
                )),
            ],
        ),

        # ----------------------------------------------------------------
        # 4. Create SixesHoleResult
        # ----------------------------------------------------------------
        migrations.CreateModel(
            name='SixesHoleResult',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('hole_number',    models.PositiveSmallIntegerField()),
                ('team1_best_net', models.SmallIntegerField(null=True, blank=True)),
                ('team2_best_net', models.SmallIntegerField(null=True, blank=True)),
                ('holes_up_after', models.SmallIntegerField(
                    default=0,
                    help_text='Running margin after this hole: +ve = team1 leading.',
                )),
                ('winning_team', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name='holes_won',
                    to='games.sixesteam',
                )),
                ('segment', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='hole_results',
                    to='games.sixessegment',
                )),
            ],
            options={
                'ordering': ['hole_number'],
                'unique_together': {('segment', 'hole_number')},
            },
        ),

        # ----------------------------------------------------------------
        # 5. Create NassauGame (9-9-18 format)
        # ----------------------------------------------------------------
        migrations.CreateModel(
            name='NassauGame',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('press_pct', models.DecimalField(
                    decimal_places=2, max_digits=4, default='0.50',
                    help_text='Press bet as a fraction of the round bet_unit (e.g. 0.50 = half).',
                )),
                ('front9_result',  models.CharField(max_length=10, choices=NASSAU_RESULT,
                                                    null=True, blank=True)),
                ('back9_result',   models.CharField(max_length=10, choices=NASSAU_RESULT,
                                                    null=True, blank=True)),
                ('overall_result', models.CharField(max_length=10, choices=NASSAU_RESULT,
                                                    null=True, blank=True)),
                ('status', models.CharField(max_length=20, choices=MATCH_STATUS,
                                            default='pending')),
                ('foursome', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='nassau_game',
                    to='tournament.foursome',
                )),
            ],
        ),

        # ----------------------------------------------------------------
        # 6. Create NassauTeam (teams for the 9-9-18 game)
        # ----------------------------------------------------------------
        migrations.CreateModel(
            name='NassauTeam',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('team_number', models.PositiveSmallIntegerField()),
                ('players', models.ManyToManyField(related_name='nassau_teams',
                                                   to='core.player')),
                ('game', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='teams',
                    to='games.nassaugame',
                )),
            ],
        ),

        # ----------------------------------------------------------------
        # 7. Create NassauHoleScore
        # ----------------------------------------------------------------
        migrations.CreateModel(
            name='NassauHoleScore',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('hole_number',    models.PositiveSmallIntegerField()),
                ('team1_best_net', models.SmallIntegerField(null=True, blank=True)),
                ('team2_best_net', models.SmallIntegerField(null=True, blank=True)),
                ('winner', models.CharField(max_length=10, choices=NASSAU_RESULT,
                                            null=True, blank=True)),
                ('front9_up_after', models.SmallIntegerField(
                    null=True, blank=True,
                    help_text='Running front-9 margin after this hole (holes 1-9 only).',
                )),
                ('back9_up_after', models.SmallIntegerField(
                    null=True, blank=True,
                    help_text='Running back-9 margin after this hole (holes 10-18 only).',
                )),
                ('game', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='hole_scores',
                    to='games.nassaugame',
                )),
            ],
            options={
                'ordering': ['hole_number'],
                'unique_together': {('game', 'hole_number')},
            },
        ),

        # ----------------------------------------------------------------
        # 8. Create NassauPress
        # ----------------------------------------------------------------
        migrations.CreateModel(
            name='NassauPress',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('nine', models.CharField(
                    max_length=5,
                    choices=[('front', 'Front 9'), ('back', 'Back 9')],
                )),
                ('triggered_on_hole', models.PositiveSmallIntegerField()),
                ('start_hole',        models.PositiveSmallIntegerField()),
                ('end_hole',          models.PositiveSmallIntegerField()),
                ('result', models.CharField(max_length=10, choices=NASSAU_RESULT,
                                            null=True, blank=True)),
                ('holes_up', models.SmallIntegerField(
                    null=True, blank=True,
                    help_text='Final margin of this press: +ve = team1 won.',
                )),
                ('game', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='presses',
                    to='games.nassaugame',
                )),
            ],
            options={
                'ordering': ['triggered_on_hole'],
            },
        ),
    ]
