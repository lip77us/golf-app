"""
management command: seed_demo
-----------------------------
Builds a complete, deterministic **demo account** for App Store review and
screenshots — and doubles as an end-to-end smoke/regression test (it drives
the real model + service layer; if it runs clean, round setup and every
game's settlement math provably work).

Creates ONE tenant ("DemoClub") with:
  * Reviewer logins (an admin + a disposable non-admin for testing
    account deletion + a couple of member logins)
  * A ~12-player roster (some with logins, some score-only)
  * One course + tee
  * Casual rounds: completed Skins, completed Points 5-3-1, completed
    Nassau, plus in-progress Sixes and in-progress Skins
  * Tournaments: one completed (2 foursomes) and one in-progress

Usage
-----
    python manage.py seed_demo            # build (errors if DemoClub exists)
    python manage.py seed_demo --reset    # tear down + rebuild deterministically
    python manage.py seed_demo --reset --password 'MyDemoPass1'

Run it against the SAME backend the submitted app points at (Railway prod),
since the reviewer's app talks to that server.

NOTE: model/service usage here follows the *current* schema (Round.course is
a Course; Tee.course is its FK) — mirroring scoring/tests/_helpers.py. The
older seed_test_data command predates a refactor and is not a reliable
template.
"""

import random
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from accounts.models import Account
from core.models import Course, HandicapMode, Player, PlayerSex, Tee
from tournament.models import Foursome, FoursomeMembership, Round, Tournament
from scoring.models import HoleScore
from rest_framework.authtoken.models import Token

from services.skins import setup_skins, calculate_skins
from services.points_531 import setup_points_531, calculate_points_531
from services.nassau import setup_nassau, calculate_nassau
from services.sixes import setup_sixes, calculate_sixes

User = get_user_model()

ACCOUNT_NAME = 'DemoClub'
DEFAULT_PASSWORD = 'HalvedDemo2026'

# Par-72 layout; hole 1 is SI 7 so stroke order isn't trivially hole==SI.
DEMO_HOLES = [
    {'number':  1, 'par': 4, 'stroke_index':  7, 'yards': 400},
    {'number':  2, 'par': 4, 'stroke_index':  3, 'yards': 410},
    {'number':  3, 'par': 3, 'stroke_index': 15, 'yards': 175},
    {'number':  4, 'par': 5, 'stroke_index':  9, 'yards': 520},
    {'number':  5, 'par': 4, 'stroke_index':  1, 'yards': 440},
    {'number':  6, 'par': 4, 'stroke_index': 13, 'yards': 380},
    {'number':  7, 'par': 3, 'stroke_index': 17, 'yards': 165},
    {'number':  8, 'par': 5, 'stroke_index': 11, 'yards': 540},
    {'number':  9, 'par': 4, 'stroke_index':  5, 'yards': 420},
    {'number': 10, 'par': 4, 'stroke_index':  8, 'yards': 395},
    {'number': 11, 'par': 4, 'stroke_index':  4, 'yards': 415},
    {'number': 12, 'par': 3, 'stroke_index': 16, 'yards': 170},
    {'number': 13, 'par': 5, 'stroke_index': 10, 'yards': 530},
    {'number': 14, 'par': 4, 'stroke_index':  2, 'yards': 445},
    {'number': 15, 'par': 4, 'stroke_index': 14, 'yards': 385},
    {'number': 16, 'par': 3, 'stroke_index': 18, 'yards': 160},
    {'number': 17, 'par': 5, 'stroke_index': 12, 'yards': 535},
    {'number': 18, 'par': 4, 'stroke_index':  6, 'yards': 425},
]

# Roster. login=None → score-only player (no sign-in). admin only on reviewer.
# `phone` (E.164) is set on login users so the phone/OTP flow is exercisable in
# the demo; production reviewers still use username/password (console SMS can't
# reach Apple's reviewer).
ROSTER = [
    {'name': 'Paul Avery',  'hcp': 9.4,  'sex': 'M', 'login': 'reviewer',        'admin': True,  'phone': '+13105550101'},
    {'name': 'Sam Tester',  'hcp': 16.0, 'sex': 'M', 'login': 'reviewer_delete', 'admin': False, 'phone': '+13105550102'},
    {'name': 'Dave Miller', 'hcp': 12.8, 'sex': 'M', 'login': 'dmiller',         'admin': False, 'phone': '+13105550103'},
    {'name': 'Sara Lopez',  'hcp': 7.2,  'sex': 'W', 'login': 'slopez',          'admin': False, 'phone': '+13105550104'},
    {'name': 'Tom Hill',    'hcp': 18.5, 'sex': 'M'},
    {'name': 'Jen Park',    'hcp': 22.0, 'sex': 'W'},
    {'name': 'Mike Ross',   'hcp': 4.5,  'sex': 'M'},
    {'name': 'Linda Cho',   'hcp': 14.0, 'sex': 'W'},
    {'name': 'Greg Bell',   'hcp': 27.3, 'sex': 'M'},
    {'name': 'Amy Fox',     'hcp': 11.1, 'sex': 'W'},
    {'name': 'Ken Yu',      'hcp': 20.2, 'sex': 'M'},
    {'name': 'Beth Ono',    'hcp': 30.0, 'sex': 'W'},
]


class Command(BaseCommand):
    help = "Build (or rebuild with --reset) the DemoClub account for App Store review."

    def add_arguments(self, parser):
        parser.add_argument(
            '--reset', action='store_true', default=False,
            help='Tear down an existing DemoClub account and rebuild it.',
        )
        parser.add_argument(
            '--password', default=DEFAULT_PASSWORD,
            help=f'Password for all demo logins (default: {DEFAULT_PASSWORD}).',
        )
        parser.add_argument(
            '--seed', type=int, default=2026,
            help='RNG seed for reproducible scores (default: 2026).',
        )

    @transaction.atomic
    def handle(self, *args, **options):
        self.password = options['password']
        self.rng = random.Random(options['seed'])

        existing = Account.objects.filter(name__iexact=ACCOUNT_NAME).first()
        if existing:
            if not options['reset']:
                raise CommandError(
                    f"Account '{ACCOUNT_NAME}' already exists. "
                    f"Pass --reset to tear it down and rebuild."
                )
            self._teardown(existing)

        account = Account.objects.create(name=ACCOUNT_NAME)
        self.stdout.write(f"Created account: {account.name}")

        players = self._create_roster(account)
        course, tee = self._create_course(account)
        self._seed_catalog()
        admin_player = players['Paul Avery']

        self.stdout.write("Building casual rounds...")
        # 1. Completed Skins (4 players, carryover)
        self._round(
            account, course, tee, 'complete', ['skins'],
            [players[n] for n in ('Paul Avery', 'Dave Miller', 'Sara Lopez', 'Mike Ross')],
            holes=18, created_by=admin_player, bet_unit='5.00',
            setup=lambda fs, ps: setup_skins(fs, carryover=True),
            calc=calculate_skins,
        )
        # 2. Completed Points 5-3-1 (exactly 3 players)
        self._round(
            account, course, tee, 'complete', ['points_531'],
            [players[n] for n in ('Tom Hill', 'Jen Park', 'Greg Bell')],
            holes=18, created_by=admin_player, bet_unit='1.00',
            setup=lambda fs, ps: setup_points_531(fs),
            calc=calculate_points_531,
        )
        # 3. Completed Nassau (2v2, auto presses)
        self._round(
            account, course, tee, 'complete', ['nassau'],
            [players[n] for n in ('Sara Lopez', 'Mike Ross', 'Linda Cho', 'Amy Fox')],
            holes=18, created_by=admin_player, bet_unit='5.00',
            setup=lambda fs, ps: setup_nassau(
                fs, [ps[0].id, ps[1].id], [ps[2].id, ps[3].id],
                press_mode='auto', press_unit=2.00,
            ),
            calc=calculate_nassau,
        )
        # 4. In-progress Sixes (6 of 18 holes — first segment)
        self._round(
            account, course, tee, 'in_progress', ['sixes'],
            [players[n] for n in ('Paul Avery', 'Dave Miller', 'Ken Yu', 'Beth Ono')],
            holes=6, created_by=admin_player, bet_unit='5.00',
            setup=self._sixes_setup,
            calc=calculate_sixes,
        )
        # 5. In-progress Skins (9 of 18 holes)
        self._round(
            account, course, tee, 'in_progress', ['skins'],
            [players[n] for n in ('Tom Hill', 'Jen Park', 'Amy Fox', 'Ken Yu')],
            holes=9, created_by=admin_player, bet_unit='5.00',
            setup=lambda fs, ps: setup_skins(fs, carryover=True),
            calc=calculate_skins,
        )

        self.stdout.write("Building tournaments...")
        # A. Completed tournament — 2 foursomes (8 players), Skins per group.
        tourn_a = Tournament.objects.create(
            account=account, name='Spring Member-Member',
            start_date=timezone.now().date(), total_rounds=1,
            active_games=['low_net'],
        )
        rnd_a = self._make_round(
            account, course, 'complete', ['skins'],
            tournament=tourn_a, round_number=1, created_by=admin_player,
        )
        self._add_foursome(
            rnd_a, tee,
            [players[n] for n in ('Paul Avery', 'Dave Miller', 'Sara Lopez', 'Mike Ross')],
            group_number=1, holes=18,
            setup=lambda fs, ps: setup_skins(fs, carryover=True), calc=calculate_skins,
        )
        self._add_foursome(
            rnd_a, tee,
            [players[n] for n in ('Tom Hill', 'Jen Park', 'Linda Cho', 'Greg Bell')],
            group_number=2, holes=18,
            setup=lambda fs, ps: setup_skins(fs, carryover=True), calc=calculate_skins,
        )

        # B. In-progress tournament — 1 foursome, 9 holes scored.
        tourn_b = Tournament.objects.create(
            account=account, name='Club Championship',
            start_date=timezone.now().date(), total_rounds=1,
            active_games=['low_net'],
        )
        rnd_b = self._make_round(
            account, course, 'in_progress', ['skins'],
            tournament=tourn_b, round_number=1, created_by=admin_player,
        )
        self._add_foursome(
            rnd_b, tee,
            [players[n] for n in ('Mike Ross', 'Sara Lopez', 'Amy Fox', 'Ken Yu')],
            group_number=1, holes=9,
            setup=lambda fs, ps: setup_skins(fs, carryover=True), calc=calculate_skins,
        )

        self._print_summary(account)

    # -----------------------------------------------------------------------
    # Teardown (correct order to avoid PROTECT errors — see CLAUDE.md notes)
    # -----------------------------------------------------------------------
    def _teardown(self, account):
        # Rounds first: cascades Foursome → FoursomeMembership, HoleScore, and
        # all per-foursome game rows (all CASCADE off Foursome). This clears
        # the PROTECT references onto Player and Tee.
        Round.objects.filter(account=account).delete()
        Tournament.objects.filter(account=account).delete()
        Player.objects.filter(account=account).delete()   # now unprotected
        Course.objects.filter(account=account).delete()    # cascades Tees
        User.objects.filter(account=account).delete()       # cascades tokens
        account.delete()
        # The shared catalog is account-agnostic; clear the demo seeds so a
        # rebuild doesn't collide on the unique golf_api_id.
        from core.models import CatalogCourse
        CatalogCourse.objects.filter(golf_api_id__startswith='seed-').delete()
        self.stdout.write(self.style.WARNING(f"  Tore down existing '{ACCOUNT_NAME}'."))

    # -----------------------------------------------------------------------
    # Builders
    # -----------------------------------------------------------------------
    def _create_roster(self, account) -> dict:
        players = {}
        for r in ROSTER:
            player = Player.objects.create(
                account=account, name=r['name'],
                handicap_index=Decimal(str(r['hcp'])),
                sex=r.get('sex', PlayerSex.MALE),
            )
            if r.get('login'):
                user = User.objects.create_user(
                    username=r['login'], password=self.password, account=account,
                )
                user.email = f"{r['login']}@demo.golf"
                if r.get('phone'):
                    user.phone = r['phone']
                    user.phone_verified_at = timezone.now()
                if r.get('admin'):
                    user.is_account_admin = True
                user.save()
                Token.objects.get_or_create(user=user)
                player.user = user
                player.save(update_fields=['user'])
            players[r['name']] = player
        self.stdout.write(f"  Created {len(players)} players "
                          f"({sum(1 for r in ROSTER if r.get('login'))} with logins).")
        return players

    def _create_course(self, account):
        course = Course.objects.create(account=account, name='Pinecrest Golf Club')
        tee = Tee.objects.create(
            course=course, tee_name='White', slope=122,
            course_rating=Decimal('71.2'), par=72, holes=DEMO_HOLES,
        )
        self.stdout.write(f"  Created course: {course.name} ({tee.tee_name} tee)")
        return course, tee

    def _seed_catalog(self):
        """Seed the global shared catalog so the in-app 'Find your course' flow
        is demoable without a GolfCourseAPI key.  The catalog is account-agnostic
        (no tenant), so we seed it once per build."""
        from core.models import CatalogCourse, CatalogTee
        catalog = [
            ('seed-1001', 'Riverbend Golf Club',   'Austin',     'TX'),
            ('seed-1002', 'Lakeside Links',         'Minneapolis', 'MN'),
            ('seed-1003', 'Coastal Pines Golf Course', 'Savannah', 'GA'),
        ]
        for api_id, name, city, state in catalog:
            cc = CatalogCourse.objects.create(
                golf_api_id=api_id, name=name, city=city, state=state,
                country='United States',
            )
            for tname, slope, rating, pri in (
                ('Blue', 130, Decimal('72.4'), 10),
                ('White', 122, Decimal('70.6'), 20),
            ):
                CatalogTee.objects.create(
                    catalog_course=cc, tee_name=tname, slope=slope,
                    course_rating=rating, par=72, sex='M',
                    default_sort_priority=pri, holes=DEMO_HOLES,
                )
        self.stdout.write(f"  Seeded {len(catalog)} shared-catalog courses.")

    def _make_round(self, account, course, status, active_games, *,
                    tournament=None, round_number=1, created_by=None,
                    bet_unit='5.00', handicap_mode=HandicapMode.NET):
        return Round.objects.create(
            account=account, course=course, status=status,
            active_games=active_games, tournament=tournament,
            round_number=round_number, created_by=created_by,
            bet_unit=Decimal(bet_unit), handicap_mode=handicap_mode,
            net_percent=100, net_max_double_bogey=True,
        )

    def _add_foursome(self, rnd, tee, players, *, group_number=1, holes=18,
                      setup=None, calc=None):
        fs = Foursome.objects.create(round=rnd, group_number=group_number)
        for p in players:
            ch = p.course_handicap(tee)
            FoursomeMembership.objects.create(
                foursome=fs, player=p, tee=tee,
                course_handicap=ch, playing_handicap=ch,
            )
        if setup:
            setup(fs, players)
        self._score(fs, tee, holes)
        if calc:
            calc(fs)
        return fs

    def _round(self, account, course, tee, status, active_games, players, *,
               holes=18, created_by=None, bet_unit='5.00', setup=None, calc=None):
        """Casual round = one Round + one Foursome."""
        rnd = self._make_round(
            account, course, status, active_games,
            created_by=created_by, bet_unit=bet_unit,
        )
        self._add_foursome(rnd, tee, players, holes=holes, setup=setup, calc=calc)
        label = ','.join(active_games)
        self.stdout.write(f"  {status:<12} {label:<11} "
                          f"({len(players)}p, {holes} holes)")
        return rnd

    def _sixes_setup(self, fs, players):
        # Proper Sixes rotation: across the three 6-hole segments each player
        # partners with each of the other three exactly once.
        #   Seg 1: A+B vs C+D
        #   Seg 2: A+C vs B+D
        #   Seg 3: A+D vs B+C
        a, b, c, d = [p.id for p in players]   # exactly 4
        team_data = [
            {'start_hole': 1,  'end_hole': 6,  'team_select_method': 'random',
             'team1_player_ids': [a, b], 'team2_player_ids': [c, d]},
            {'start_hole': 7,  'end_hole': 12, 'team_select_method': 'random',
             'team1_player_ids': [a, c], 'team2_player_ids': [b, d]},
            {'start_hole': 13, 'end_hole': 18, 'team_select_method': 'random',
             'team1_player_ids': [a, d], 'team2_player_ids': [b, c]},
        ]
        setup_sixes(fs, team_data)

    # -----------------------------------------------------------------------
    # Score generation — deterministic given --seed; each player plays roughly
    # to handicap (net ≈ par) with a small handicap-tiered variance.
    # -----------------------------------------------------------------------
    def _score(self, fs, tee, holes_to_score):
        members = list(
            FoursomeMembership.objects
            .filter(foursome=fs, player__is_phantom=False)
            .select_related('player')
        )
        for m in members:
            for hole in range(1, holes_to_score + 1):
                hd = tee.hole(hole)
                si, par = hd['stroke_index'], hd['par']
                strokes = m.handicap_strokes_on_hole(si)
                variance = self.rng.choices(
                    [-1, 0, 1, 2], weights=self._weights(m.playing_handicap),
                )[0]
                gross = max(1, par + variance + strokes)
                HoleScore.objects.update_or_create(
                    foursome=fs, player=m.player, hole_number=hole,
                    defaults={'gross_score': gross, 'handicap_strokes': strokes},
                )

    @staticmethod
    def _weights(playing_handicap):
        if playing_handicap <= 8:
            return [15, 50, 25, 10]
        if playing_handicap <= 18:
            return [5, 40, 40, 15]
        if playing_handicap <= 28:
            return [2, 30, 45, 23]
        return [1, 20, 45, 34]

    # -----------------------------------------------------------------------
    def _print_summary(self, account):
        rounds = Round.objects.filter(account=account)
        self.stdout.write("")
        self.stdout.write(self.style.SUCCESS("=" * 64))
        self.stdout.write(self.style.SUCCESS("  DemoClub seeded successfully"))
        self.stdout.write(self.style.SUCCESS("=" * 64))
        self.stdout.write(f"  Account name : {account.name}")
        self.stdout.write(f"  Players      : {Player.objects.filter(account=account).count()}")
        self.stdout.write(f"  Rounds       : {rounds.count()} "
                          f"({rounds.filter(status='complete').count()} complete, "
                          f"{rounds.filter(status='in_progress').count()} in progress)")
        self.stdout.write(f"  Tournaments  : {Tournament.objects.filter(account=account).count()}")
        self.stdout.write("")
        self.stdout.write("  Logins (account name + username + password):")
        for r in ROSTER:
            if r.get('login'):
                role = 'admin' if r.get('admin') else 'member'
                self.stdout.write(
                    f"    {account.name} / {r['login']:<16} / {self.password}   ({role})"
                )
        self.stdout.write("")
        self.stdout.write("  For App Store review notes:")
        self.stdout.write(f"    Account: {account.name}   Username: reviewer   "
                          f"Password: {self.password}")
        self.stdout.write("    Test account deletion with the non-admin login "
                          "'reviewer_delete' (Settings → Delete Account).")
        self.stdout.write(self.style.SUCCESS("=" * 64))
