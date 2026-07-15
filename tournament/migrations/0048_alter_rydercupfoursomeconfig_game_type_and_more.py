from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('tournament', '0047_alter_rydercupfoursomeconfig_game_type_and_more'),
    ]

    operations = [
        migrations.AlterField(
            model_name='rydercupfoursomeconfig',
            name='game_type',
            field=models.CharField(choices=[('irish_rumble', 'Irish Rumble'), ('nassau', 'Nassau'), ('nassau_nine', 'Nassau Nine'), ('match_18', 'Singles Match'), ('sixes', 'Sixes'), ('pink_ball', 'Pink Ball'), ('scramble', 'Scramble'), ('stableford', 'Stableford'), ('skins', 'Skins'), ('multi_skins', 'Multi-Group Skins'), ('low_net_round', 'Low Net (Round)'), ('low_net', 'Low Net Championship'), ('points_531', 'Points 5-3-1'), ('three_person_match', 'Three-Person Match'), ('match_play', 'Mini Singles Bracket'), ('quota_nassau', 'Quota Nassau'), ('singles_nassau', 'Singles Nassau'), ('singles_18', '18-Hole Singles'), ('triple_cup', 'One-Round Triple Cup'), ('wolf', 'Wolf'), ('rabbit', 'Rabbit'), ('vegas', 'Las Vegas'), ('fourball', 'Fourball'), ('spots', 'Spots'), ('honors', 'Honors')], help_text='Game this foursome plays. Must be a GameType value supported by the app (nassau, quota_nassau, irish_rumble, match_play, etc.).', max_length=30),
        ),
        migrations.AlterField(
            model_name='rydercupmatchpoints',
            name='game_type',
            field=models.CharField(choices=[('irish_rumble', 'Irish Rumble'), ('nassau', 'Nassau'), ('nassau_nine', 'Nassau Nine'), ('match_18', 'Singles Match'), ('sixes', 'Sixes'), ('pink_ball', 'Pink Ball'), ('scramble', 'Scramble'), ('stableford', 'Stableford'), ('skins', 'Skins'), ('multi_skins', 'Multi-Group Skins'), ('low_net_round', 'Low Net (Round)'), ('low_net', 'Low Net Championship'), ('points_531', 'Points 5-3-1'), ('three_person_match', 'Three-Person Match'), ('match_play', 'Mini Singles Bracket'), ('quota_nassau', 'Quota Nassau'), ('singles_nassau', 'Singles Nassau'), ('singles_18', '18-Hole Singles'), ('triple_cup', 'One-Round Triple Cup'), ('wolf', 'Wolf'), ('rabbit', 'Rabbit'), ('vegas', 'Las Vegas'), ('fourball', 'Fourball'), ('spots', 'Spots'), ('honors', 'Honors')], max_length=30),
        ),
    ]
