from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0013_alter_irishrumbleconfig_payouts_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='lownetroundconfig',
            name='excluded_player_ids',
            field=models.JSONField(
                default=list,
                help_text=(
                    "Player IDs excluded from prize payouts. "
                    "Excluded players still appear in standings so their "
                    "score is visible, but they cannot win money."
                ),
            ),
        ),
    ]
