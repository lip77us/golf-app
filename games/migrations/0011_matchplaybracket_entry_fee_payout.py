from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0010_entry_fee_payouts'),
    ]

    operations = [
        migrations.AddField(
            model_name='matchplaybracket',
            name='entry_fee',
            field=models.DecimalField(
                decimal_places=2,
                default=0.00,
                help_text='Per-player entry fee for the match play prize pool.',
                max_digits=7,
            ),
        ),
        migrations.AddField(
            model_name='matchplaybracket',
            name='payout_config',
            field=models.JSONField(
                blank=True,
                default=dict,
                help_text=(
                    'Dict of place → dollar amount. '
                    'E.g. {"1st": 48.00, "2nd": 24.00, "3rd": 8.00, "4th": 0.00}'
                ),
            ),
        ),
    ]
