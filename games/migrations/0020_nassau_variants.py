# Generated manually — Nassau variants (tiebreak_2nd, claremont)

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0019_threepersonmatch_tiebreak_status'),
    ]

    operations = [
        # NassauGame — variant + bottom bet results
        migrations.AddField(
            model_name='nassaugame',
            name='variant',
            field=models.CharField(
                max_length=20,
                choices=[
                    ('none',         'Standard Nassau'),
                    ('tiebreak_2nd', '2nd-Ball Tie-Break'),
                    ('claremont',    'Claremont'),
                ],
                default='none',
                help_text='Game variant: standard, 2nd-ball tie-break, or Claremont.',
            ),
        ),
        migrations.AddField(
            model_name='nassaugame',
            name='bottom_front9_result',
            field=models.CharField(
                max_length=10,
                choices=[('team1', 'Team 1'), ('team2', 'Team 2'), ('halved', 'Halved')],
                null=True, blank=True,
            ),
        ),
        migrations.AddField(
            model_name='nassaugame',
            name='bottom_back9_result',
            field=models.CharField(
                max_length=10,
                choices=[('team1', 'Team 1'), ('team2', 'Team 2'), ('halved', 'Halved')],
                null=True, blank=True,
            ),
        ),
        migrations.AddField(
            model_name='nassaugame',
            name='bottom_overall_result',
            field=models.CharField(
                max_length=10,
                choices=[('team1', 'Team 1'), ('team2', 'Team 2'), ('halved', 'Halved')],
                null=True, blank=True,
            ),
        ),

        # NassauHoleScore — 2nd-ball + claremont bottom fields
        migrations.AddField(
            model_name='nassauholescore',
            name='team1_2nd_net',
            field=models.SmallIntegerField(null=True, blank=True),
        ),
        migrations.AddField(
            model_name='nassauholescore',
            name='team2_2nd_net',
            field=models.SmallIntegerField(null=True, blank=True),
        ),
        migrations.AddField(
            model_name='nassauholescore',
            name='bottom_delta',
            field=models.SmallIntegerField(
                null=True, blank=True,
                help_text='Net bottom points for team1 this hole: +2..−2. Claremont only.',
            ),
        ),
        migrations.AddField(
            model_name='nassauholescore',
            name='bottom_front9_up_after',
            field=models.SmallIntegerField(null=True, blank=True),
        ),
        migrations.AddField(
            model_name='nassauholescore',
            name='bottom_back9_up_after',
            field=models.SmallIntegerField(null=True, blank=True),
        ),
        migrations.AddField(
            model_name='nassauholescore',
            name='bottom_overall_up_after',
            field=models.SmallIntegerField(null=True, blank=True),
        ),

        # NassauPress — side field ('top' | 'bottom')
        migrations.AddField(
            model_name='nassaupress',
            name='side',
            field=models.CharField(
                max_length=10,
                choices=[
                    ('top',    'Top (best-ball Nassau)'),
                    ('bottom', 'Bottom (Claremont 2-pt game)'),
                ],
                default='top',
                help_text="'top' = Nassau best-ball press; 'bottom' = Claremont 2-pt press.",
            ),
        ),

        # Update NassauPress ordering (side first, then triggered_on_hole)
        migrations.AlterModelOptions(
            name='nassaupress',
            options={'ordering': ['side', 'triggered_on_hole']},
        ),
    ]
