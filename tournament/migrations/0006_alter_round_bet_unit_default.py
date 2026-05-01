from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0005_alter_foursome_active_games'),
    ]

    operations = [
        migrations.AlterField(
            model_name='round',
            name='bet_unit',
            field=models.DecimalField(decimal_places=2, default=5.0, max_digits=6),
        ),
    ]
