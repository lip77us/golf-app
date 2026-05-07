from django.db import migrations, models


class Migration(migrations.Migration):
    """
    Actually adds the format_declarations column to RyderCupRoundConfig.

    Migration 0018 was edited-in-place after it had already been applied
    locally (it originally added total_possible_points to TeamTournament),
    so the column was never created locally.  However, on Railway (and any
    fresh DB), 0018 ran with its current content and already created the
    column.

    Using SeparateDatabaseAndState + ADD COLUMN IF NOT EXISTS makes this
    migration safe on both environments:
      - Fresh / Railway DB: column already exists → IF NOT EXISTS skips it.
      - Local DB (0018 applied with old content): column missing → adds it.
    """

    dependencies = [
        ('tournament', '0019_alter_rydercupfoursomeconfig_game_type_and_more'),
    ]

    operations = [
        migrations.SeparateDatabaseAndState(
            database_operations=[
                migrations.RunSQL(
                    sql="""
                        ALTER TABLE tournament_rydercuproundconfig
                        ADD COLUMN IF NOT EXISTS format_declarations jsonb NULL;
                    """,
                    reverse_sql=migrations.RunSQL.noop,
                ),
            ],
            state_operations=[
                migrations.AddField(
                    model_name='rydercuproundconfig',
                    name='format_declarations',
                    field=models.JSONField(
                        blank=True,
                        null=True,
                        help_text=(
                            'Declared game formats for this round. '
                            'Used to compute total_possible before foursomes are '
                            'configured. Each entry: {"game_type": str, "units": int, '
                            '"point_value": str}. units = foursomes for nassau/quota/'
                            'singles; pairings for irish_rumble.'
                        ),
                    ),
                ),
            ],
        ),
    ]
