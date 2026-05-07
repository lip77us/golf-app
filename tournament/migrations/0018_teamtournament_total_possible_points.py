from django.db import migrations, models


class Migration(migrations.Migration):
    """
    Adds format_declarations to RyderCupRoundConfig so that per-round
    total_possible_points can be declared before foursomes are configured.

    Replaces the earlier (never-deployed) total_possible_points field on
    TeamTournament — that approach was too coarse-grained.
    """

    dependencies = [
        ('tournament', '0017_fix_team_fk_protect_to_cascade'),
    ]

    operations = [
        migrations.AddField(
            model_name='rydercuproundconfig',
            name='format_declarations',
            field=models.JSONField(
                blank=True,
                null=True,
                help_text=(
                    'Declared game formats for this round. '
                    'Used to compute total_possible before foursomes are '
                    'configured. Each entry: {"game_type": str, "units": int, '
                    '"point_value": str}. units = foursomes for nassau/quota/'
                    'singles; pairings for irish_rumble.'
                ),
            ),
        ),
    ]
