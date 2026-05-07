from django.db import migrations, models


class Migration(migrations.Migration):
    """
    Actually adds the format_declarations column to RyderCupRoundConfig.

    Migration 0018 was edited-in-place after it had already been applied
    (it originally added total_possible_points to TeamTournament), so the
    column was never created.  Migration 0019's AlterField also assumed the
    column existed and generated no DDL.  This migration is the real AddField.
    """

    dependencies = [
        ('tournament', '0019_alter_rydercupfoursomeconfig_game_type_and_more'),
    ]

    operations = [
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
    ]
