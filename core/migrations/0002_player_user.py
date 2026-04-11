from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0001_initial'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AddField(
            model_name='player',
            name='user',
            field=models.OneToOneField(
                blank=True,
                help_text='Linked Django user account for API token auth.',
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name='player_profile',
                to=settings.AUTH_USER_MODEL,
            ),
        ),
    ]
