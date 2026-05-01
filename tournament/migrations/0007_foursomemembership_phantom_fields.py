from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0006_alter_round_bet_unit_default'),
    ]

    operations = [
        migrations.AddField(
            model_name='foursomemembership',
            name='phantom_algorithm',
            field=models.CharField(
                max_length=50,
                default='rotating_player_scores',
                help_text='Algorithm id from scoring.phantom.REGISTRY used to generate phantom scores.',
            ),
        ),
        migrations.AddField(
            model_name='foursomemembership',
            name='phantom_config',
            field=models.JSONField(
                default=dict,
                help_text='Algorithm-specific config (e.g. rotation order). Populated by PhantomInitView.',
            ),
        ),
    ]
