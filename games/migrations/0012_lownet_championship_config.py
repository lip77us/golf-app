import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0011_matchplaybracket_entry_fee_payout'),
        ('tournament', '0001_initial'),
    ]

    operations = [
        migrations.CreateModel(
            name='LowNetChampionshipConfig',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('handicap_mode', models.CharField(
                    choices=[('gross', 'Gross'), ('net', 'Net'), ('strokes_off', 'Strokes Off Low')],
                    default='net', max_length=20,
                )),
                ('net_percent', models.PositiveSmallIntegerField(
                    default=100,
                    help_text="Percentage of playing handicap applied when handicap_mode='net'.",
                )),
                ('entry_fee', models.DecimalField(
                    decimal_places=2, default=0.0,
                    help_text='Per-player entry fee.',
                    max_digits=8,
                )),
                ('payouts', models.JSONField(
                    default=list,
                    help_text=(
                        "Payout per finishing place. "
                        "Example: [{'place': 1, 'amount': 200.00}, {'place': 2, 'amount': 100.00}]"
                    ),
                )),
                ('tournament', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='low_net_championship_config',
                    to='tournament.tournament',
                )),
            ],
        ),
    ]
