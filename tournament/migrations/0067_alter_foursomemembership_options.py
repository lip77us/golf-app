"""Foursome memberships come back in creation order.

Meta-only, so there is no SQL — but it is the fix for two unordered queries
disagreeing about who is who: a game's scorecard listed the four golfers in
one order while its score entry, reading the same foursome through the
serializer, listed them in another.
"""

from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0066_alter_rydercupfoursomeconfig_game_type_and_more'),
    ]

    operations = [
        migrations.AlterModelOptions(
            name='foursomemembership',
            options={'ordering': ['id']},
        ),
    ]
