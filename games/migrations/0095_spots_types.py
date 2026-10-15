"""Spots gains named types, the greenie pick and its carry.

**Hand-written because `spot_type` is NOT NULL with no model default**, which
the autodetector cannot add without being told what to backfill. The honest
answer is that there is nothing to backfill: `SpotsPlayerHoleResult` is empty
in local AND in production (checked 15 Oct 2026 — zero Spots games, zero
rows), so the field is added with a DDL-only default that is not preserved on
the model.

That same emptiness is why `count` is DROPPED rather than migrated into a
type. A signed count could say "three spots of some unnamed kind" and could go
negative for a penalty; the types carry both jobs and carry them better — the
named type says WHAT, and `SpotType.SNAKE` is the penalty. Had there been a
single row anywhere this would have been an AddField plus a data migration
mapping each count to that many `OTHER` ticks, which is worth knowing if the
same shape ever needs undoing.
"""
from django.db import migrations, models
import django.core.validators
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0094_sologame_auto_press'),
        ('core', '0016_favoritegolfer'),
    ]

    operations = [
        # ── which spots are in play, and how they are read ──
        migrations.AddField(
            model_name='spotsgame',
            name='types',
            field=models.JSONField(
                default=list,
                help_text='SpotType slugs in play. At least one.'),
        ),
        migrations.AddField(
            model_name='spotsgame',
            name='greenie_carry',
            field=models.BooleanField(
                default=True,
                help_text='An unclaimed greenie rolls to the next par 3.'),
        ),
        migrations.AddField(
            model_name='spotsgame',
            name='birdie_basis',
            field=models.CharField(
                choices=[('gross', 'Gross'), ('net_so', 'Net (SO)')],
                default='gross', max_length=8),
        ),
        migrations.AddField(
            model_name='spotsgame',
            name='net_percent',
            field=models.SmallIntegerField(
                default=100,
                help_text='Allowance for the strokes-off birdie basis.'),
        ),

        # ── the result row becomes a tick of one named type ──
        # Order matters: the old unique_together names `count`'s sibling
        # columns, so it has to come off before the column does.
        migrations.AlterUniqueTogether(
            name='spotsplayerholeresult',
            unique_together=set(),
        ),
        migrations.RemoveField(
            model_name='spotsplayerholeresult',
            name='count',
        ),
        migrations.AddField(
            model_name='spotsplayerholeresult',
            name='spot_type',
            field=models.CharField(
                choices=[('greenie', 'Greenie'), ('sandy', 'Sandy'),
                         ('poley', 'Poley'), ('birdie', 'Birdie'),
                         ('eagle', 'Eagle or better'), ('chippy', 'Chippy'),
                         ('barky', 'Barky'), ('snake', 'Snake'),
                         ('other', 'Other')],
                default='other', max_length=12),
            preserve_default=False,
        ),
        migrations.AlterModelOptions(
            name='spotsplayerholeresult',
            options={'ordering': ['hole_number', 'player_id', 'spot_type']},
        ),
        migrations.AlterUniqueTogether(
            name='spotsplayerholeresult',
            unique_together={('game', 'player', 'hole_number', 'spot_type')},
        ),

        # ── the greenie pick ──
        migrations.CreateModel(
            name='SpotsGreenieResult',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('hole_number', models.PositiveSmallIntegerField(validators=[
                    django.core.validators.MinValueValidator(1),
                    django.core.validators.MaxValueValidator(18)])),
                ('game', models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='greenies', to='games.spotsgame')),
                ('player', models.ForeignKey(
                    blank=True, null=True,
                    help_text='Null = nobody hit the green.',
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='spots_greenies', to='core.player')),
            ],
            options={
                'ordering': ['hole_number'],
                'unique_together': {('game', 'hole_number')},
            },
        ),
    ]
