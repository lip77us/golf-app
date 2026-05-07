from django.db import migrations, models


class Migration(migrations.Migration):
    """
    Adds cup_group_counts to Round so the wizard can record how many
    groups play each game type per cup round.  This lets cup_standings_summary
    compute total_possible for every round up-front, even before the cup
    round setup screen has been run.
    """

    dependencies = [
        ('tournament', '0020_rydercuproundconfig_format_declarations_real'),
    ]

    operations = [
        migrations.AddField(
            model_name='round',
            name='cup_group_counts',
            field=models.JSONField(
                default=dict,
                blank=True,
                help_text=(
                    'Number of groups (foursomes) playing each game type in '
                    'this cup round. Set at wizard time. '
                    'e.g. {"quota_nassau": 3} or {"irish_rumble": 2, "singles_nassau": 1}.'
                ),
            ),
        ),
    ]
