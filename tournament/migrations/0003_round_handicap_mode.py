from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0002_round_created_by'),
    ]

    operations = [
        migrations.AddField(
            model_name='round',
            name='handicap_mode',
            field=models.CharField(
                choices=[('gross', 'Gross'), ('net', 'Net'), ('strokes_off', 'Strokes Off Low')],
                default='net',
                help_text='Handicap mode applied to all games in this round.',
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name='round',
            name='net_percent',
            field=models.PositiveSmallIntegerField(
                default=100,
                help_text='Percentage of handicap applied when mode=net (0–200).',
            ),
        ),
    ]
