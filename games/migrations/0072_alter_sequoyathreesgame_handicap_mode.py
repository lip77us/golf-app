"""Sequoya 3s defaults to strokes-off-low.

A Django-level default, so the SQL is a no-op and **existing rows keep
whatever they stored** — a round already set up as net stays net and keeps
scoring the way it was played.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0071_sequoyathreesgame_sequoyathreespress'),
    ]

    operations = [
        migrations.AlterField(
            model_name='sequoyathreesgame',
            name='handicap_mode',
            field=models.CharField(choices=[('net', 'Net'), ('gross', 'Gross'), ('strokes_off', 'Strokes Off Low')], default='strokes_off', max_length=20),
        ),
    ]
