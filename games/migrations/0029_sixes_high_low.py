# Hand-written migration: adds High-Low scoring format + round-wide
# handicap allocation toggle to Sixes.  Also adds per-team point and
# worst-net fields to SixesHoleResult so high_low can store its 2-points-
# per-hole breakdown.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0028_irish_rumble_variant'),
    ]

    operations = [
        # ── SixesSegment: format + handicap allocation knobs ────────────────
        migrations.AddField(
            model_name='sixessegment',
            name='scoring_format',
            field=models.CharField(
                max_length=20,
                choices=[
                    ('classic',  'Classic (best ball, 1 pt/hole)'),
                    ('high_low', 'High-Low (best+worst, 2 pts/hole)'),
                ],
                default='classic',
                help_text=(
                    "Scoring rules.  'classic' = best-ball 1 pt/hole "
                    "with extras; 'high_low' = low+high 2 pts/hole, "
                    "3 segments only, strict point-based closeout."
                ),
            ),
        ),
        migrations.AddField(
            model_name='sixessegment',
            name='handicap_allocation',
            field=models.CharField(
                max_length=20,
                choices=[
                    ('per_segment', 'Spread across 3 segments'),
                    ('full_round',  'Round-wide (strokes on hardest holes)'),
                ],
                default='per_segment',
                help_text=(
                    "Only meaningful for handicap_mode='strokes_off'. "
                    "'per_segment' splits SO across the 3 matches "
                    "(legacy default); 'full_round' allocates strokes "
                    "by round-wide stroke index instead."
                ),
            ),
        ),

        # ── SixesHoleResult: high_low extra fields ──────────────────────────
        migrations.AddField(
            model_name='sixesholeresult',
            name='team1_worst_net',
            field=models.SmallIntegerField(null=True, blank=True,
                help_text="High-Low only: the higher of team 1's two nets."),
        ),
        migrations.AddField(
            model_name='sixesholeresult',
            name='team2_worst_net',
            field=models.SmallIntegerField(null=True, blank=True,
                help_text="High-Low only: the higher of team 2's two nets."),
        ),
        migrations.AddField(
            model_name='sixesholeresult',
            name='team1_points',
            field=models.PositiveSmallIntegerField(
                default=0,
                help_text="Points awarded to team 1 on this hole (0/1 classic, 0-2 high_low).",
            ),
        ),
        migrations.AddField(
            model_name='sixesholeresult',
            name='team2_points',
            field=models.PositiveSmallIntegerField(
                default=0,
                help_text="Points awarded to team 2 on this hole (0/1 classic, 0-2 high_low).",
            ),
        ),
        migrations.AddField(
            model_name='sixesholeresult',
            name='counts_for_segment',
            field=models.BooleanField(
                default=True,
                help_text=(
                    "High-Low only: False for holes played after the "
                    "segment closed out — the score is recorded but "
                    "doesn't add to segment points."
                ),
            ),
        ),
    ]
