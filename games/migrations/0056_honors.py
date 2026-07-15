import django.core.validators
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0011_player_ghin'),
        ('games', '0055_multiskinslinkedround'),
        ('tournament', '0047_alter_rydercupfoursomeconfig_game_type_and_more'),
    ]

    operations = [
        migrations.CreateModel(
            name='HonorsGame',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('status', models.CharField(choices=[('pending', 'Pending'), ('in_progress', 'In Progress'), ('complete', 'Complete'), ('halved', 'Halved')], default='pending', max_length=20)),
                ('handicap_mode', models.CharField(choices=[('net', 'Net'), ('gross', 'Gross'), ('strokes_off', 'Strokes Off Low')], default='net', help_text='How per-hole scores are adjusted for ranking.', max_length=20)),
                ('net_percent', models.PositiveSmallIntegerField(default=100, help_text="Percentage of playing handicap applied when handicap_mode='net'.", validators=[django.core.validators.MinValueValidator(0), django.core.validators.MaxValueValidator(200)])),
                ('loss_cap', models.DecimalField(blank=True, decimal_places=2, help_text='Optional per-side loss cap (one table-wide value applied per player). Null = uncapped. When set, losers clip at the cap and winners are reduced pro-rata — see services.wager.settle().', max_digits=8, null=True)),
                ('payout_style', models.CharField(choices=[('pool', 'Pool'), ('per_point', 'Per point')], default='per_point', max_length=12)),
                ('per_point_mode', models.CharField(choices=[('average', 'Settle vs the field average'), ('all', 'Pay everyone above you'), ('first', 'Pay the leader')], default='average', max_length=8)),
                ('participant_player_ids', models.JSONField(blank=True, default=list)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('foursome', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='honors_game', to='tournament.foursome')),
            ],
        ),
        migrations.CreateModel(
            name='HonorsHoleResult',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('hole_number', models.PositiveSmallIntegerField(validators=[django.core.validators.MinValueValidator(1), django.core.validators.MaxValueValidator(18)])),
                ('game', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='hole_results', to='games.honorsgame')),
                ('holder', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='honors_holes_held', to='core.player')),
                ('winner', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='honors_holes_won', to='core.player')),
            ],
            options={
                'ordering': ['hole_number'],
                'unique_together': {('game', 'hole_number')},
            },
        ),
    ]
