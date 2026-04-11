from tournament.models import Round
from services.round_setup import setup_round, create_phantom_hole_scores

round_obj = Round.objects.first()
player_ids = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]  # adjust to your actual PKs

foursomes = setup_round(round_obj, player_ids)
for fs in foursomes:
    print(fs, [m.player.name for m in fs.memberships.all()])
    if fs.has_phantom:
        create_phantom_hole_scores(fs)