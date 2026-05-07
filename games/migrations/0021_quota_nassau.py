# Generated manually — Quota Nassau game models

import django.core.validators
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0003_player_short_name'),
        ('games', '0020_nassau_variants'),
        ('tournament', '0009_ryder_cup_models'),
    ]

    operations = [

        # ── QuotaNassauGame ────────────────────────────────────────────────
        migrations.CreateModel(
            name='QuotaNassauGame',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('status', models.CharField(
                    choices=[
                        ('pending', 'Pending'),
                        ('in_progress', 'In Progress'),
                        ('complete', 'Complete'),
                        ('halved', 'Halved'),
                    ],
                    default='pending',
                    max_length=20,
                )),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('foursome', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='quota_nassau_games',
                    to='tournament.foursome',
                )),
            ],
        ),

        # ── QuotaNassauMatch ───────────────────────────────────────────────
        migrations.CreateModel(
            name='QuotaNassauMatch',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('player1_quota', models.SmallIntegerField(
                    help_text='36 − player1\'s course handicap index at setup time.',
                )),
                ('player2_quota', models.SmallIntegerField(
                    help_text='36 − player2\'s course handicap index at setup time.',
                )),
                ('front9_result', models.CharField(
                    blank=True, max_length=10, null=True,
                    choices=[('player1', 'Player 1'), ('player2', 'Player 2'), ('halved', 'Halved')],
                )),
                ('back9_result', models.CharField(
                    blank=True, max_length=10, null=True,
                    choices=[('player1', 'Player 1'), ('player2', 'Player 2'), ('halved', 'Halved')],
                )),
                ('overall_result', models.CharField(
                    blank=True, max_length=10, null=True,
                    choices=[('player1', 'Player 1'), ('player2', 'Player 2'), ('halved', 'Halved')],
                )),
                ('status', models.CharField(
                    choices=[
                        ('pending', 'Pending'),
                        ('in_progress', 'In Progress'),
                        ('complete', 'Complete'),
                        ('halved', 'Halved'),
                    ],
                    default='pending',
                    max_length=20,
                )),
                ('game', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='matches',
                    to='games.quotanassaugame',
                )),
                ('player1', models.ForeignKey(
                    on_delete=django.db.models.deletion.PROTECT,
                    related_name='quota_nassau_as_p1',
                    to='core.player',
                )),
                ('player2', models.ForeignKey(
                    on_delete=django.db.models.deletion.PROTECT,
                    related_name='quota_nassau_as_p2',
                    to='core.player',
                )),
            ],
        ),
        migrations.AddConstraint(
            model_name='quotanassaumatch',
            constraint=models.UniqueConstraint(
                fields=['game', 'player1', 'player2'],
                name='unique_quota_match_pairing',
            ),
        ),

        # ── QuotaNassauHoleResult ──────────────────────────────────────────
        migrations.CreateModel(
            name='QuotaNassauHoleResult',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('hole_number', models.PositiveSmallIntegerField(
                    validators=[
                        django.core.validators.MinValueValidator(1),
                        django.core.validators.MaxValueValidator(18),
                    ],
                )),
                ('p1_stableford', models.SmallIntegerField(
                    blank=True, null=True,
                    help_text='Stableford points player1 earned this hole (0–5).',
                )),
                ('p2_stableford', models.SmallIntegerField(
                    blank=True, null=True,
                    help_text='Stableford points player2 earned this hole (0–5).',
                )),
                ('p1_score_vs_quota', models.DecimalField(
                    blank=True, decimal_places=2, max_digits=6, null=True,
                    help_text='p1 cumulative stableford − (quota × hole/18). +ve = above quota, −ve = below.',
                )),
                ('p2_score_vs_quota', models.DecimalField(
                    blank=True, decimal_places=2, max_digits=6, null=True,
                )),
                ('front9_margin_after', models.DecimalField(
                    blank=True, decimal_places=2, max_digits=6, null=True,
                    help_text='Front-9 margin after this hole (holes 1–9 only).',
                )),
                ('back9_margin_after', models.DecimalField(
                    blank=True, decimal_places=2, max_digits=6, null=True,
                    help_text='Back-9 margin after this hole (holes 10–18 only).',
                )),
                ('overall_margin_after', models.DecimalField(
                    blank=True, decimal_places=2, max_digits=6, null=True,
                    help_text='Overall (18-hole) running margin after this hole.',
                )),
                ('match', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='hole_results',
                    to='games.quotanassaumatch',
                )),
            ],
            options={
                'ordering': ['hole_number'],
            },
        ),
        migrations.AddConstraint(
            model_name='quotanassauholeresult',
            constraint=models.UniqueConstraint(
                fields=['match', 'hole_number'],
                name='unique_quota_hole_per_match',
            ),
        ),
    ]
