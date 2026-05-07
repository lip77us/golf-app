# Hand-written repair migration.
#
# Background: 0009_ryder_cup_models used CreateModel for TeamTournament, but
# the table was already present in some databases from an earlier iteration.
# Django marked the migration applied without running the DDL, so cup_name
# (and potentially players_per_team / draft_complete) were never added to the
# real table.
#
# This migration uses ADD COLUMN IF NOT EXISTS (Postgres 9.6+) so it is safe
# to run on any environment regardless of current schema state.

from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0011_foursome_tee_time'),
    ]

    operations = [
        migrations.RunSQL(
            sql="""
                ALTER TABLE tournament_teamtournament
                    ADD COLUMN IF NOT EXISTS cup_name VARCHAR(100) NOT NULL DEFAULT 'Ryder Cup',
                    ADD COLUMN IF NOT EXISTS players_per_team SMALLINT NOT NULL DEFAULT 6,
                    ADD COLUMN IF NOT EXISTS draft_complete   BOOLEAN  NOT NULL DEFAULT FALSE,
                    ADD COLUMN IF NOT EXISTS created_at       TIMESTAMPTZ;

                -- Back-fill created_at for any rows that already exist
                UPDATE tournament_teamtournament
                   SET created_at = NOW()
                 WHERE created_at IS NULL;
            """,
            reverse_sql="""
                ALTER TABLE tournament_teamtournament
                    DROP COLUMN IF EXISTS cup_name,
                    DROP COLUMN IF EXISTS players_per_team,
                    DROP COLUMN IF EXISTS draft_complete,
                    DROP COLUMN IF EXISTS created_at;
            """,
        ),
    ]
