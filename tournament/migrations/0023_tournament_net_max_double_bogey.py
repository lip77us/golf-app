from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0022_alter_round_cup_group_counts_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='tournament',
            name='net_max_double_bogey',
            field=models.BooleanField(
                default=False,
                help_text=(
                    "When true, every player's per-hole score in this "
                    "tournament's rounds is capped at net par + 2 for "
                    "game-scoring purposes (max-double-bogey rule). "
                    "Applies only to games whose handicap mode is Net "
                    "or Strokes-Off; gross-mode games are unaffected. "
                    "Stored gross scores are never modified."
                ),
            ),
        ),
    ]
