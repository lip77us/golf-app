from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0010_remove_tournamentteam_unique_team_number_per_tournament_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='foursome',
            name='tee_time',
            field=models.TimeField(
                blank=True,
                null=True,
                help_text='Scheduled tee time for this group (HH:MM).',
            ),
        ),
    ]
