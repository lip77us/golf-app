from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0003_round_handicap_mode'),
    ]

    operations = [
        migrations.AddField(
            model_name='foursome',
            name='active_games',
            field=models.JSONField(
                default=list,
                help_text=(
                    "Games active for this specific foursome. "
                    "When empty the round-level active_games applies (backward compat)."
                ),
            ),
        ),
    ]
