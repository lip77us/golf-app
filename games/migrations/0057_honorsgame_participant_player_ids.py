from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0056_honors'),
    ]

    operations = [
        migrations.AddField(
            model_name='honorsgame',
            name='participant_player_ids',
            field=models.JSONField(blank=True, default=list),
        ),
    ]
