"""
Migration 0017: Fix PROTECT → CASCADE on TournamentTeam foreign keys.

RyderCupFoursomeConfig.team1/team2, RyderCupIrishRumblePairing.team_a/team_b,
and RyderCupMatchPoints.team1/team2 were set to PROTECT, which prevented
deleting a Tournament (and its cascaded TeamTournament / TournamentTeam records)
when Ryder Cup round data existed.  These should CASCADE so the whole tournament
tree deletes cleanly.
"""
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0016_alter_round_game_point_values'),
    ]

    operations = [
        # RyderCupFoursomeConfig.team1
        migrations.AlterField(
            model_name='rydercupfoursomeconfig',
            name='team1',
            field=models.ForeignKey(
                blank=True, null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='foursome_configs_as_t1',
                to='tournament.tournamentteam',
            ),
        ),
        # RyderCupFoursomeConfig.team2
        migrations.AlterField(
            model_name='rydercupfoursomeconfig',
            name='team2',
            field=models.ForeignKey(
                blank=True, null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='foursome_configs_as_t2',
                to='tournament.tournamentteam',
            ),
        ),
        # RyderCupIrishRumblePairing.team_a
        migrations.AlterField(
            model_name='rydercupirishrumblepairing',
            name='team_a',
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name='rumble_pairings_as_a',
                to='tournament.tournamentteam',
            ),
        ),
        # RyderCupIrishRumblePairing.team_b
        migrations.AlterField(
            model_name='rydercupirishrumblepairing',
            name='team_b',
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name='rumble_pairings_as_b',
                to='tournament.tournamentteam',
            ),
        ),
        # RyderCupMatchPoints.team1
        migrations.AlterField(
            model_name='rydercupmatchpoints',
            name='team1',
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name='ryder_points_as_t1',
                to='tournament.tournamentteam',
            ),
        ),
        # RyderCupMatchPoints.team2
        migrations.AlterField(
            model_name='rydercupmatchpoints',
            name='team2',
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name='ryder_points_as_t2',
                to='tournament.tournamentteam',
            ),
        ),
    ]
