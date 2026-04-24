from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0008_pink_ball_config'),
    ]

    operations = [
        migrations.AddField(
            model_name='pinkballconfig',
            name='places_paid',
            field=models.PositiveSmallIntegerField(default=1),
        ),
    ]
