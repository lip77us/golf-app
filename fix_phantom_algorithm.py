"""
Diagnose and fix cross-foursome phantom memberships for Nassau (Four Ball).

Run from your backend directory:
    python manage.py shell < ../fix_phantom_algorithm.py

Or drop it next to manage.py and run:
    python manage.py shell < fix_phantom_algorithm.py
"""

import django
from tournament.models import Round, Foursome, FoursomeMembership
from scoring.phantom import CROSS_FOURSOME_ALGORITHM_ID, setup_cross_foursome_phantom

# ── 1. Diagnose all phantom memberships ─────────────────────────────────────
print("\n=== All foursomes with a phantom player ===")
phantom_mems = (
    FoursomeMembership.objects
    .filter(player__is_phantom=True)
    .select_related('player', 'foursome__round')
    .order_by('-foursome__round__date')
)

if not phantom_mems.exists():
    print("  (none found)")

for pm in phantom_mems:
    fs   = pm.foursome
    rnd  = fs.round
    algo = pm.phantom_algorithm or '(not set)'
    cfg  = pm.phantom_config or {}
    rotation = cfg.get('rotation', [])
    print(
        f"  Round {rnd.id} ({rnd.date})  "
        f"Foursome {fs.id}  "
        f"Games: {fs.active_games}  "
        f"Phantom: {pm.player.name}  "
        f"Algorithm: {algo}  "
        f"Donors: {rotation}"
    )

# ── 2. Find Nassau phantom memberships that are missing the algorithm ────────
print("\n=== Nassau phantom memberships missing cross_foursome_rotation ===")
broken = list(
    FoursomeMembership.objects
    .filter(player__is_phantom=True)
    .select_related('player', 'foursome__round')
)
nassau_broken = [
    pm for pm in broken
    if 'nassau' in (pm.foursome.active_games or [])
    and pm.phantom_algorithm != CROSS_FOURSOME_ALGORITHM_ID
]

if not nassau_broken:
    print("  None — algorithm is already set correctly for all Nassau phantoms.")
else:
    for pm in nassau_broken:
        fs  = pm.foursome
        rnd = fs.round
        print(f"\n  Foursome {fs.id} (Round {rnd.id} / {rnd.date}): {pm.player.name}")
        print(f"    active_games : {fs.active_games}")
        print(f"    algorithm    : {pm.phantom_algorithm!r}")

        # Find the cup config for this foursome to determine the phantom's team
        phantom_team = None
        try:
            from tournament.models import RyderCupFoursomeConfig
            cup_cfg = RyderCupFoursomeConfig.objects.get(foursome=fs)
            t1_pids = set(cup_cfg.team1.players.values_list('id', flat=True)) if cup_cfg.team1 else set()
            t2_pids = set(cup_cfg.team2.players.values_list('id', flat=True)) if cup_cfg.team2 else set()
            real_pids = set(
                FoursomeMembership.objects
                .filter(foursome=fs, player__is_phantom=False)
                .values_list('player_id', flat=True)
            )
            t1_real = len(real_pids & t1_pids)
            t2_real = len(real_pids & t2_pids)
            phantom_team = cup_cfg.team1 if t1_real < t2_real else cup_cfg.team2
            print(f"    phantom team : {phantom_team.name if phantom_team else '(none)'}")
            print(f"    t1_real={t1_real}  t2_real={t2_real}")

            # Show what donors WOULD be found
            if phantom_team:
                team_pids = set(phantom_team.players.values_list('id', flat=True))
                donor_mems = list(
                    FoursomeMembership.objects
                    .filter(
                        foursome__round=rnd,
                        player_id__in=team_pids,
                        player__is_phantom=False,
                    )
                    .exclude(foursome=fs)
                    .select_related('player', 'foursome')
                )
                print(f"    potential donors ({len(donor_mems)}): "
                      f"{[(d.player.name, d.foursome_id) for d in donor_mems]}")
        except Exception as e:
            print(f"    cup config error: {e}")

        if phantom_team is None:
            print("    SKIPPING — cannot identify phantom team")
            continue

        # Attempt fix
        print(f"    Calling setup_cross_foursome_phantom ...")
        ok = setup_cross_foursome_phantom(fs, phantom_team, rnd)
        if ok:
            pm.refresh_from_db()
            cfg2 = pm.phantom_config or {}
            print(f"    ✓ OK — algorithm={pm.phantom_algorithm}  "
                  f"donors={cfg2.get('rotation', [])}  "
                  f"playing_hcp={pm.playing_handicap}")
        else:
            print("    ✗ FAILED — setup_cross_foursome_phantom returned False")
            print("      (No donors found in other foursomes for this team)")

print("\n=== Done ===")
