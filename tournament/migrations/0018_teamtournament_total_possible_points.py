from django.db import migrations, models


class Migration(migrations.Migration):
    """
    Adds format_declarations to RyderCupRoundConfig so that per-round
    total_possible_points can be declared before foursomes are configured.

    Replaces the earlier (never-deployed) total_possible_points field on
    TeamTournament — that approach was too coarse-grained.

    Uses IF NOT EXISTS so the migration is safe to apply against a database
    that already has the column (e.g. from a previous manual migration or
    out-of-order deploy).
    """

    dependencies = [
        ('tournament', '0017_fix_team_fk_protect_to_cascade'),
    ]

    operations = [
        # Use raw SQL with IF NOT EXISTS so this is idempotent — safe to run
        # even if the column was already added by a previous deploy or manually.
        migrations.RunSQL(
            sql="""
                ALTER TABLE tournament_rydercuproundconfig
                ADD COLUMN IF NOT EXISTS format_declarations jsonb NULL;
            """,
            reverse_sql="""
                ALTER TABLE tournament_rydercuproundconfig
                DROP COLUMN IF EXISTS format_declarations;
            """,
        ),
        # Tell Django's ORM about the field so subsequent AlterField migrations
        # have a consistent state to work from.
        migrations.AlterField(
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
    ]
