from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0023_tournament_net_max_double_bogey'),
    ]

    operations = [
        migrations.RemoveField(
            model_name='tournament',
            name='net_max_double_bogey',
        ),
        migrations.AddField(
            model_name='round',
            name='net_max_double_bogey',
            field=models.BooleanField(
                default=True,
                help_text=(
                    "When true, every player's per-hole score in this "
                    "round is capped at net par + 2 for game-scoring "
                    "purposes (max-double-bogey rule). Applies only to "
                    "games whose handicap mode is Net or Strokes-Off; "
                    "gross-mode games are unaffected. Stored gross "
                    "scores are never modified. For tournament rounds, "
                    "set this via the Tournament-wide bulk action in "
                    "admin."
                ),
            ),
        ),
    ]
