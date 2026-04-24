from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0007_irish_rumble_config_low_net_config'),
        ('tournament', '0001_initial'),
    ]

    operations = [
        migrations.CreateModel(
            name='PinkBallConfig',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('ball_color', models.CharField(default='Pink', max_length=50)),
                ('bet_unit', models.DecimalField(decimal_places=2, default=1.0, max_digits=8)),
                ('round', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='pink_ball_config',
                    to='tournament.round',
                )),
            ],
            options={
                'verbose_name': 'Pink Ball Config',
            },
        ),
    ]
