"""
management command: seed_test_data
-----------------------------------
Populates the database with a fully playable test round so you can
develop and test the mobile app without clicking through the admin.

Usage
-----
    # Basic — round + 2 foursomes, no scores, no games
    python manage.py seed_test_data

    # Pick which games to activate
    python manage.py seed_test_data --games skins nassau sixes stableford pink_ball match_play

    # Also fill all 18 holes with realistic scores and run calculators
    python manage.py seed_test_data --scores

    # Wipe all previous test data first, then reseed
    python manage.py seed_test_data --clear --scores --games skins nassau sixes stableford

    # Keep player order fixed (no randomisation) — useful for reproducible tests
    python manage.py seed_test_data --no-randomise --scores

What gets created
-----------------
* 1 Tee: "Cypress Ridge — White"  (par 72, slope 130, rating 72.4)
* 8 Players: Test_Alice … Test_Henry  (handicap 4–36, each linked to a
  Django user with password "golf1234")
* 1 Tournament: "Test Tournament"
* 1 Round tied to the tournament  (status in_progress)
* 2 Foursomes set up via services.round_setup.setup_round
* If --scores: 18 holes of realistic gross scores per player, then all
  game calculators are run
* If nassau in --games: teams 1+3 vs 2+4 per foursome
* If sixes in --games: standard 3×6-hole rotation
* If match_play in --games: bracket seeded by course handicap

All test objects carry "Test_" prefix on Tournament/Player names so
clear_test_data (or --clear) can identify and remove only test data.
"""

import random

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone

from core.models import Player, Tee
from tournament.models import Tournament, Round, Foursome, FoursomeMembership
from services.round_setup import setup_round, create_phantom_hole_scores

User = get_user_model()

# ---------------------------------------------------------------------------
# Course data — a generic par-72 with realistic stroke indexes
# ---------------------------------------------------------------------------

CYPRESS_RIDGE_HOLES = [
    {"number":  1, "par": 4, "stroke_index":  7, "yards": 392},
    {"number":  2, "par": 3, "stroke_index": 15, "yards": 178},
    {"number":  3, "par": 5, "stroke_index":  3, "yards": 521},
    {"number":  4, "par": 4, "stroke_index": 11, "yards": 375},
    {"number":  5, "par": 4, "stroke_index":  1, "yards": 448},
    {"number":  6, "par": 3, "stroke_index": 17, "yards": 156},
    {"number":  7, "par": 5, "stroke_index":  5, "yards": 538},
    {"number":  8, "par": 4, "stroke_index": 13, "yards": 363},
    {"number":  9, "par": 4, "stroke_index":  9, "yards": 401},
    {"number": 10, "par": 4, "stroke_index":  2, "yards": 432},
    {"number": 11, "par": 3, "stroke_index": 16, "yards": 169},
    {"number": 12, "par": 5, "stroke_index":  4, "yards": 507},
    {"number": 13, "par": 4, "stroke_index": 12, "yards": 358},
    {"number": 14, "par": 4, "stroke_index":  8, "yards": 415},
    {"number": 15, "par": 3, "stroke_index": 18, "yards": 143},
    {"number": 16, "par": 5, "stroke_index":  6, "yards": 549},
    {"number": 17, "par": 4, "stroke_index": 10, "yards": 388},
    {"number": 18, "par": 4, "stroke_index": 14, "yards": 371},
]

# ---------------------------------------------------------------------------
# Test players — name, handicap_index, username, email
# ---------------------------------------------------------------------------

TEST_PLAYERS = [
    {"name": "Test_Alice",   "handicap_index": 4.2,  "username": "test_alice",   "email": "alice@test.golf"},
    {"name": "Test_Bob",     "handicap_index": 8.7,  "username": "test_bob",     "email": "bob@test.golf"},
    {"name": "Test_Carol",   "handicap_index": 13.1, "username": "test_carol",   "email": "carol@test.golf"},
    {"name": "Test_Dave",    "handicap_index": 17.4, "username": "test_dave",    "email": "dave@test.golf"},
    {"name": "Test_Eve",     "handicap_index": 21.0, "username": "test_eve",     "email": "eve@test.golf"},
    {"name": "Test_Frank",   "handicap_index": 25.3, "username": "test_frank",   "email": "frank@test.golf"},
    {"name": "Test_Grace",   "handicap_index": 29.6, "username": "test_grace",   "email": "grace@test.golf"},
    {"name": "Test_Henry",   "handicap_index": 36.0, "username": "test_henry",   "email": "henry@test.golf"},
]

TEST_PASSWORD = "golf1234"


# ---------------------------------------------------------------------------
# Score generation
# ---------------------------------------------------------------------------

def _gross_score(par: int, stroke_index: int, playing_handicap: int,
                 rng: random.Random) -> int:
    """
    Generate a realistic gross score for one hole.

    Strategy: each player "plays to their handicap" on average, meaning
    their expected NET score is around par.  We add a small random variance:
        -1  (birdie net)  with low probability
         0  (par net)     most likely
        +1  (bogey net)   likely
        +2  (double net)  occasional
    The distribution tightens for scratch players and loosens for high caps.

    Returns a gross score (net + handicap_strokes_received).
    """
    strokes_received = _strokes_on_hole(playing_handicap, stroke_index)

    # Variance weights [−1, 0, +1, +2] tuned by handicap tier
    if playing_handicap <= 8:
        weights = [15, 50, 25, 10]   # low-cap: lots of pars, some birdies
    elif playing_handicap <= 18:
        weights = [5, 40, 40, 15]    # mid-cap: mostly pars/bogeys net
    elif playing_handicap <= 28:
        weights = [2, 30, 45, 23]    # high-cap: mostly bogeys net
    else:
        weights = [1, 20, 45, 34]    # very high: bogeys & doubles net

    variance = rng.choices([-1, 0, 1, 2], weights=weights)[0]
    net  = par + variance
    gross = net + strokes_received
    return max(gross, 1)             # can't score less than 1


def _strokes_on_hole(playing_handicap: int, stroke_index: int) -> int:
    """Mirror of FoursomeMembership.handicap_strokes_on_hole."""
    full_strokes = playing_handicap // 18
    remainder    = playing_handicap % 18
    extra        = 1 if stroke_index <= remainder else 0
    return full_strokes + extra


# ---------------------------------------------------------------------------
# Main command
# ---------------------------------------------------------------------------

VALID_GAMES = {
    'skins', 'nassau', 'sixes', 'stableford',
    'pink_ball', 'match_play', 'low_net_round', 'irish_rumble', 'scramble',
}


class Command(BaseCommand):
    help = (
        "Seed the database with a test round (2 foursomes, 8 players) "
        "for mobile-app development."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--games',
            nargs='*',
            metavar='GAME',
            default=['skins', 'nassau', 'sixes', 'stableford', 'pink_ball'],
            help=(
                f"Active games to set up. Choices: {', '.join(sorted(VALID_GAMES))}. "
                "Default: skins nassau sixes stableford pink_ball"
            ),
        )
        parser.add_argument(
            '--scores',
            action='store_true',
            default=False,
            help='Fill all 18 holes with realistic scores and run game calculators.',
        )
        parser.add_argument(
            '--clear',
            action='store_true',
            default=False,
            help='Wipe all existing test data before seeding.',
        )
        parser.add_argument(
            '--no-randomise',
            action='store_true',
            default=False,
            help='Keep player order fixed instead of shuffling into foursomes.',
        )
        parser.add_argument(
            '--seed',
            type=int,
            default=None,
            help='Random seed for reproducible score generation.',
        )

    @transaction.atomic
    def handle(self, *args, **options):
        games     = options['games'] or []
        do_scores = options['scores']
        do_clear  = options['clear']
        randomise = not options['no_randomise']
        rng_seed  = options['seed']

        # Validate game names
        bad = set(games) - VALID_GAMES
        if bad:
            self.stderr.write(f"Unknown game(s): {', '.join(bad)}. "
                              f"Valid choices: {', '.join(sorted(VALID_GAMES))}")
            return

        rng = random.Random(rng_seed)

        if do_clear:
            self._clear_test_data()

        tee      = self._get_or_create_tee()
        players  = self._get_or_create_players()
        tourney  = self._get_or_create_tournament(games)
        round_obj = self._create_round(tourney, tee, games)

        player_ids = [p.pk for p in players]
        foursomes  = setup_round(round_obj, player_ids, randomise=randomise)

        for fs in foursomes:
            if fs.has_phantom:
                create_phantom_hole_scores(fs)

        self.stdout.write(
            f"  Created {len(foursomes)} foursome(s) with "
            f"{sum(fs.player_count() for fs in foursomes)} real players."
        )

        # Game-specific setup
        for fs in foursomes:
            self._setup_games(fs, games, rng)

        if do_scores:
            self._seed_scores(foursomes, rng)
            self._run_calculators(round_obj, foursomes, games)

        self._print_summary(round_obj, foursomes, games, do_scores)

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    def _clear_test_data(self):
        """Remove all objects whose name starts with 'Test_'."""
        from scoring.models import HoleScore

        # Foursomes (cascade to HoleScore, SkinsResult, game tables)
        test_rounds = Round.objects.filter(tournament__name__startswith='Test_')
        Foursome.objects.filter(round__in=test_rounds).delete()

        Tournament.objects.filter(name__startswith='Test_').delete()

        # Players + their users
        test_players = Player.objects.filter(name__startswith='Test_')
        for p in test_players:
            if p.user:
                p.user.delete()   # cascades to auth_token too
        test_players.delete()

        Tee.objects.filter(course_name='Cypress Ridge').delete()

        self.stdout.write(self.style.WARNING("  Cleared previous test data."))

    def _get_or_create_tee(self) -> Tee:
        tee, created = Tee.objects.get_or_create(
            course_name='Cypress Ridge',
            tee_name='White',
            defaults={
                'slope'        : 130,
                'course_rating': '72.4',
                'par'          : 72,
                'holes'        : CYPRESS_RIDGE_HOLES,
            },
        )
        status = "Created" if created else "Found"
        self.stdout.write(f"  {status} tee: {tee}")
        return tee

    def _get_or_create_players(self) -> list:
        from rest_framework.authtoken.models import Token

        players = []
        for pd in TEST_PLAYERS:
            user, u_created = User.objects.get_or_create(
                username=pd['username'],
                defaults={'email': pd['email']},
            )
            if u_created:
                user.set_password(TEST_PASSWORD)
                user.save()

            Token.objects.get_or_create(user=user)   # ensure API token exists

            player, p_created = Player.objects.get_or_create(
                name=pd['name'],
                defaults={
                    'handicap_index': pd['handicap_index'],
                    'email'         : pd['email'],
                    'user'          : user,
                },
            )
            if not p_created and player.user is None:
                player.user = user
                player.save(update_fields=['user'])

            players.append(player)
            status = "Created" if p_created else "Found"
            self.stdout.write(
                f"  {status} player: {player.name} "
                f"(hcp {player.handicap_index}, user: {user.username})"
            )

        return players

    def _get_or_create_tournament(self, games: list) -> Tournament:
        tourney, created = Tournament.objects.get_or_create(
            name='Test_Tournament',
            defaults={
                'start_date'  : timezone.now().date(),
                'total_rounds': 1,
                'active_games': games,
            },
        )
        if not created:
            # Refresh active_games in case --games changed
            tourney.active_games = games
            tourney.save(update_fields=['active_games'])

        status = "Created" if created else "Found"
        self.stdout.write(f"  {status} tournament: {tourney.name}")
        return tourney

    def _create_round(self, tourney: Tournament, tee: Tee, games: list) -> Round:
        """Always creates a fresh Round (allows multiple seed runs)."""
        existing = Round.objects.filter(tournament=tourney).count()
        round_obj = Round.objects.create(
            tournament   = tourney,
            round_number = existing + 1,
            date         = timezone.now().date(),
            course       = tee,
            status       = 'in_progress',
            active_games = games,
            bet_unit     = '5.00',
        )
        self.stdout.write(f"  Created round: {round_obj}")
        return round_obj

    def _setup_games(self, foursome: Foursome, games: list, rng: random.Random):
        """Set up per-foursome game configurations."""
        real_members = list(
            FoursomeMembership.objects
            .filter(foursome=foursome, player__is_phantom=False)
            .order_by('course_handicap')   # sort by handicap for consistent teams
            .select_related('player')
        )
        player_ids = [m.player_id for m in real_members]

        if len(player_ids) < 2:
            return   # can't set up team games with < 2 players

        # Split into two teams: alternate by handicap rank (1,3 vs 2,4)
        team1_ids = [player_ids[i] for i in range(0, len(player_ids), 2)]
        team2_ids = [player_ids[i] for i in range(1, len(player_ids), 2)]

        if 'nassau' in games:
            from services.nassau import setup_nassau
            setup_nassau(foursome, team1_ids, team2_ids, press_pct=0.50)
            self.stdout.write(
                f"    Nassau: Group {foursome.group_number} — "
                f"T1={[m.player.name for m in real_members[::2]]} vs "
                f"T2={[m.player.name for m in real_members[1::2]]}"
            )

        if 'sixes' in games:
            from services.sixes import setup_sixes
            all_ids = player_ids[:4]   # up to 4 real players

            # Each element is (team1_player_ids, team2_player_ids) for one 6-hole segment.
            # With 4 players we rotate partners across the three segments.
            if len(all_ids) >= 4:
                segment_teams = [
                    ([all_ids[0], all_ids[2]], [all_ids[1], all_ids[3]]),  # holes 1-6
                    ([all_ids[1], all_ids[3]], [all_ids[0], all_ids[2]]),  # holes 7-12
                    ([all_ids[0], all_ids[3]], [all_ids[1], all_ids[2]]),  # holes 13-18
                ]
            else:
                segment_teams = [
                    (all_ids[:1], all_ids[1:]),
                    (all_ids[1:], all_ids[:1]),
                    (all_ids[:1], all_ids[1:]),
                ]

            team_data = [
                {
                    'start_hole'        : seg_num * 6 + 1,
                    'end_hole'          : seg_num * 6 + 6,
                    'team1_player_ids'  : t1_ids,
                    'team2_player_ids'  : t2_ids,
                    'team_select_method': 'random',
                }
                for seg_num, (t1_ids, t2_ids) in enumerate(segment_teams)
            ]
            setup_sixes(foursome, team_data)
            self.stdout.write(f"    Six's: Group {foursome.group_number} — 3 segments set up.")

        if 'match_play' in games:
            from services.match_play import setup_match_play
            setup_match_play(foursome)
            self.stdout.write(f"    Match Play: Group {foursome.group_number} bracket seeded.")

    def _seed_scores(self, foursomes: list, rng: random.Random):
        """Fill all 18 holes for all real players in every foursome."""
        from scoring.models import HoleScore

        self.stdout.write("  Seeding scores...")
        total = 0

        for fs in foursomes:
            tee = fs.round.course
            members = list(
                FoursomeMembership.objects
                .filter(foursome=fs, player__is_phantom=False)
                .select_related('player')
            )

            for m in members:
                for hole in tee.holes:
                    hole_num    = hole['number']
                    hole_par    = hole['par']
                    stroke_idx  = hole['stroke_index']
                    strokes     = m.handicap_strokes_on_hole(stroke_idx)
                    gross       = _gross_score(hole_par, stroke_idx, m.playing_handicap, rng)

                    HoleScore.objects.update_or_create(
                        foursome     = fs,
                        player       = m.player,
                        hole_number  = hole_num,
                        defaults={
                            'gross_score'      : gross,
                            'handicap_strokes' : strokes,
                            # net_score + stableford auto-calculated in save()
                        },
                    )
                    total += 1

        self.stdout.write(f"  Inserted/updated {total} hole score rows.")

    def _run_calculators(self, round_obj: Round, foursomes: list, games: list):
        """Run all active game calculators to produce result rows."""
        self.stdout.write("  Running game calculators...")

        for fs in foursomes:
            if 'skins' in games:
                from services.skins import calculate_skins
                calculate_skins(fs)

            if 'nassau' in games:
                from services.nassau import calculate_nassau
                try:
                    calculate_nassau(fs)
                except Exception as e:
                    self.stderr.write(f"    Nassau calc failed (Group {fs.group_number}): {e}")

            if 'sixes' in games:
                from services.sixes import calculate_sixes
                try:
                    calculate_sixes(fs)
                except Exception as e:
                    self.stderr.write(f"    Sixes calc failed (Group {fs.group_number}): {e}")

            if 'match_play' in games:
                from services.match_play import calculate_match_play
                try:
                    calculate_match_play(fs)
                except Exception as e:
                    self.stderr.write(f"    Match Play calc failed (Group {fs.group_number}): {e}")

        if 'stableford' in games:
            from services.stableford import calculate_stableford
            calculate_stableford(round_obj)

        if 'pink_ball' in games:
            from services.red_ball import calculate_red_ball
            calculate_red_ball(round_obj)

        if 'low_net_round' in games:
            from services.low_net_round import low_net_round_standings
            low_net_round_standings(round_obj)   # read-only aggregation, no persist needed

        self.stdout.write("  Calculators done.")

    def _print_summary(self, round_obj: Round, foursomes: list,
                       games: list, scored: bool):
        from rest_framework.authtoken.models import Token

        self.stdout.write("")
        self.stdout.write(self.style.SUCCESS("=" * 60))
        self.stdout.write(self.style.SUCCESS("  Test data seeded successfully"))
        self.stdout.write(self.style.SUCCESS("=" * 60))
        self.stdout.write(f"  Round ID  : {round_obj.pk}")
        self.stdout.write(f"  Date      : {round_obj.date}")
        self.stdout.write(f"  Course    : {round_obj.course}")
        self.stdout.write(f"  Status    : {round_obj.status}")
        self.stdout.write(f"  Games     : {', '.join(games) if games else '(none)'}")
        self.stdout.write(f"  Scored    : {'yes — all 18 holes' if scored else 'no'}")
        self.stdout.write("")
        self.stdout.write("  Players & API tokens:")

        for fs in foursomes:
            members = (
                FoursomeMembership.objects
                .filter(foursome=fs, player__is_phantom=False)
                .select_related('player__user')
                .order_by('course_handicap')
            )
            self.stdout.write(f"  Group {fs.group_number}:")
            for m in members:
                player = m.player
                token  = None
                if player.user:
                    try:
                        token = Token.objects.get(user=player.user).key
                    except Token.DoesNotExist:
                        pass
                self.stdout.write(
                    f"    {player.name:<16} hcp={m.playing_handicap:<3} "
                    f"user={player.user.username if player.user else '—':<14} "
                    f"token={token or '(no token)'}"
                )

        self.stdout.write("")
        self.stdout.write(f"  API login: POST /api/auth/login/")
        self.stdout.write(f"  Password for all test users: {TEST_PASSWORD}")
        self.stdout.write(
            f"  Leaderboard: GET /api/rounds/{round_obj.pk}/leaderboard/"
        )
        for fs in foursomes:
            self.stdout.write(
                f"  Scorecard G{fs.group_number}: GET /api/foursomes/{fs.pk}/scorecard/"
            )
        self.stdout.write(self.style.SUCCESS("=" * 60))
