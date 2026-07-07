# Generated for the Golf Genius roster import (services/genius_import.py).

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0010_catalogtee_curated_catalogtee_origin'),
    ]

    operations = [
        migrations.AddField(
            model_name='player',
            name='ghin',
            field=models.CharField(blank=True, db_index=True, help_text='GHIN number; blank if the golfer has none.', max_length=10),
        ),
    ]
