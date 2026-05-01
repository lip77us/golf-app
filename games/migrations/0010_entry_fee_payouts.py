"""
Replace bet_unit (winner-take-all) with entry_fee + payouts (explicit payout
structure) on both IrishRumbleConfig and PinkBallConfig.  Also removes the
places_paid field that was added to PinkBallConfig in 0009 before the full
model was finalised.
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0009_pinkballconfig_places_paid'),
    ]

    operations = [
        # ── IrishRumbleConfig ──────────────────────────────────────────────
        migrations.AddField(
            model_name='irishrumbleconfig',
            name='entry_fee',
            field=models.DecimalField(
                decimal_places=2, default=0.0, max_digits=8,
                help_text='Entry fee per foursome; total pool = entry_fee × num_foursomes.',
            ),
        ),
        migrations.AddField(
            model_name='irishrumbleconfig',
            name='payouts',
            field=models.JSONField(
                default=list,
                help_text="Payout per finishing place. Example: [{'place': 1, 'amount': 60.00}]",
            ),
        ),
        migrations.RemoveField(
            model_name='irishrumbleconfig',
            name='bet_unit',
        ),

        # ── PinkBallConfig ─────────────────────────────────────────────────
        migrations.AddField(
            model_name='pinkballconfig',
            name='entry_fee',
            field=models.DecimalField(
                decimal_places=2, default=0.0, max_digits=8,
                help_text='Entry fee per foursome; total pool = entry_fee × num_foursomes.',
            ),
        ),
        migrations.AddField(
            model_name='pinkballconfig',
            name='payouts',
            field=models.JSONField(
                default=list,
                help_text="Payout per finishing place. Example: [{'place': 1, 'amount': 60.00}]",
            ),
        ),
        migrations.RemoveField(
            model_name='pinkballconfig',
            name='bet_unit',
        ),
        migrations.RemoveField(
            model_name='pinkballconfig',
            name='places_paid',
        ),
    ]
