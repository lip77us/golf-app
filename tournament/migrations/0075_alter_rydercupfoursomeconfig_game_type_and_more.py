"""Eclectic is renamed Dream Round: the enum's choices, and the stored slug.

The choice lists are the usual enum refresh. The data migration is the half
that matters: `active_games` is a JSON list of slugs written by the wizard, and
it is written onto the TOURNAMENT and onto each of its ROUNDS — so an event
configured before the rename would come back with a game the enum no longer
has, drop out of `_leaderboard_active_games`, and lose its tab and its
settlement pots while its config row sat there intact.

Reversible, because a rename is not a one-way door: `reverse` puts the old slug
back so this migration can be unapplied without stranding the data on a value
the previous code did not know.
"""
from django.db import migrations, models

OLD, NEW = 'eclectic', 'dream_round'

#: Every model with an `active_games` list. Foursome is included although
#: nothing writes a field game to one today — a side game reaching a foursome
#: later must not leave a slug behind that only this migration would have
#: fixed.
_MODELS = ('Tournament', 'Round', 'Foursome')


def _swap(apps, frm, to):
    for name in _MODELS:
        model = apps.get_model('tournament', name)
        for obj in model.objects.all():
            games = obj.active_games or []
            if frm in games:
                obj.active_games = [to if g == frm else g for g in games]
                obj.save(update_fields=['active_games'])
    # A casual primary is never a field side game, but the column is a plain
    # slug and costs nothing to keep honest.
    apps.get_model('tournament', 'Round').objects.filter(
        primary_game=frm).update(primary_game=to)


def forwards(apps, schema_editor):
    _swap(apps, OLD, NEW)


def backwards(apps, schema_editor):
    _swap(apps, NEW, OLD)


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0074_alter_rydercupfoursomeconfig_game_type_and_more'),
    ]

    operations = [
        migrations.AlterField(
            model_name='rydercupfoursomeconfig',
            name='game_type',
            field=models.CharField(choices=[('irish_rumble', 'Irish Rumble'), ('better_ball', 'Better Ball'), ('nassau', 'Nassau'), ('nassau_nine', 'Nassau Nine'), ('match_18', 'Singles Match'), ('triple_nassau', 'Triple Nassau'), ('sixes', 'Sixes'), ('pink_ball', 'Pink Ball'), ('dream_round', 'Dream Round'), ('forty_balls', '40 Balls'), ('scramble', 'Scramble'), ('foursomes', 'Foursomes'), ('two_man_chapman', 'Two-man Chapman'), ('stableford', 'Stableford'), ('skins', 'Skins'), ('multi_skins', 'Multi-Group Skins'), ('low_net_round', 'Low Net (Round)'), ('low_net', 'Low Net Championship'), ('points_531', 'Points 5-3-1'), ('three_person_match', 'Three-Person Match'), ('match_play', 'Mini Singles Bracket'), ('quota_nassau', 'Quota Nassau'), ('singles_nassau', 'Singles Nassau'), ('singles_18', '18-Hole Singles'), ('triple_cup', 'One-Round Triple Cup'), ('wolf', 'Wolf'), ('rabbit', 'Rabbit'), ('vegas', 'Las Vegas'), ('fourball', 'Fourball'), ('spots', 'Spots'), ('honors', 'Honors'), ('survivor', 'Survivor'), ('sequoya_threes', 'Sequoya 3s'), ('banker', 'Banker')], help_text='Game this foursome plays. Must be a GameType value supported by the app (nassau, quota_nassau, irish_rumble, match_play, etc.).', max_length=30),
        ),
        migrations.AlterField(
            model_name='rydercupmatchpoints',
            name='game_type',
            field=models.CharField(choices=[('irish_rumble', 'Irish Rumble'), ('better_ball', 'Better Ball'), ('nassau', 'Nassau'), ('nassau_nine', 'Nassau Nine'), ('match_18', 'Singles Match'), ('triple_nassau', 'Triple Nassau'), ('sixes', 'Sixes'), ('pink_ball', 'Pink Ball'), ('dream_round', 'Dream Round'), ('forty_balls', '40 Balls'), ('scramble', 'Scramble'), ('foursomes', 'Foursomes'), ('two_man_chapman', 'Two-man Chapman'), ('stableford', 'Stableford'), ('skins', 'Skins'), ('multi_skins', 'Multi-Group Skins'), ('low_net_round', 'Low Net (Round)'), ('low_net', 'Low Net Championship'), ('points_531', 'Points 5-3-1'), ('three_person_match', 'Three-Person Match'), ('match_play', 'Mini Singles Bracket'), ('quota_nassau', 'Quota Nassau'), ('singles_nassau', 'Singles Nassau'), ('singles_18', '18-Hole Singles'), ('triple_cup', 'One-Round Triple Cup'), ('wolf', 'Wolf'), ('rabbit', 'Rabbit'), ('vegas', 'Las Vegas'), ('fourball', 'Fourball'), ('spots', 'Spots'), ('honors', 'Honors'), ('survivor', 'Survivor'), ('sequoya_threes', 'Sequoya 3s'), ('banker', 'Banker')], max_length=30),
        ),
        migrations.RunPython(forwards, backwards),
    ]
