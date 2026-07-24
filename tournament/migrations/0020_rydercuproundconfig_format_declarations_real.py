from django.db import migrations


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
            # No state operations: 0018 now adds format_declarations to Django's
            # migration state (as a state-only AddField). Re-adding it here would
            # raise "field already exists" on a fresh migrate. This migration is
            # therefore database-only — it exists solely to create the column on a
            # legacy local DB where 0018 was applied under its older content.
            state_operations=[],
        ),
    ]
