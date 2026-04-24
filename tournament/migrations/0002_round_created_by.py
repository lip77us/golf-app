import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("tournament", "0001_initial"),
        ("core", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="round",
            name="created_by",
            field=models.ForeignKey(
                blank=True,
                help_text="Player who created this round. Only they may delete it.",
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="created_rounds",
                to="core.player",
            ),
        ),
    ]
