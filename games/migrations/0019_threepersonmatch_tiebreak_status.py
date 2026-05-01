# Generated manually 2026-04-29 — add 'tiebreak' and 'phase2' status choices

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0018_alter_threepersonmatch_status'),
    ]

    operations = [
        migrations.AlterField(
            model_name='threepersonmatch',
            name='status',
            field=models.CharField(
                choices=[
                    ('pending',     'Pending'),
                    ('in_progress', 'In Progress'),
                    ('tiebreak',    'Tiebreak'),
                    ('phase2',      'Phase 2'),
                    ('complete',    'Complete'),
                ],
                default='pending',
                max_length=20,
            ),
        ),
    ]
