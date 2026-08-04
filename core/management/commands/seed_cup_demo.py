"""
management command: seed_cup_demo
---------------------------------
Builds a standalone **Cup tournament** demo tenant for testing the Triple-Cup
tee-box flows (no-show removal, tee-position swap) locally — WITHOUT touching
the App-Store-reviewer `seed_demo` tenant.

Creates ONE tenant ("CupDemo") with:
  * A TD admin login + a couple of member logins
  * A roster of `groups × 4` golfers split evenly into two cup teams
  * One course + tee
  * A `team_cup` Tournament whose single round is a One-Day **Triple Cup**
    (`round_format='triple_cup'`), draft **locked**, `groups` foursomes each
    2v2, staggered tee times — and **zero scores** so the tee-box no-show /
    swap tools are exercisable (they refuse once any hole is scored).

Usage
-----
    python manage.py seed_cup_demo                 # build (errors if it exists)
    python manage.py seed_cup_demo --reset         # tear down + rebuild
    python manage.py seed_cup_demo --reset --groups 4
    python manage.py seed_cup_demo --reset --password 'MyPass1'

Then log in (account "CupDemo", the printed username + password), open
Tournaments → the cup card → tap the round, and use the ⋮ menu on a foursome
card: **Remove no-show** / **Swap tee position**.  Try removing from group 1
(the earliest) to see the donor rejection, then swap it later and retry.

Sibling of `seed_demo` — same idioms (see that file's notes on current schema).
The roster import step you'd run before a real event is a separate command:
`python manage.py import_genius_roster <path> --account "<name>"`.
"""

from datetime import time
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from accounts.models import Account
from core.models import Course, GameType, HandicapMode, Player, PlayerSex, Tee
from tournament.models import (
    Foursome, FoursomeMembership, Round, Tournament,
    TeamTournament, TournamentTeam,
    RyderCupRoundConfig, RyderCupFoursomeConfig,
)
from services.triple_cup import setup_triple_cup
from rest_framework.authtoken.models import Token

User = get_user_model()

ACCOUNT_NAME = 'CupDemo'
DEFAULT_PASSWORD = 'HalvedCup2026'

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

# A pool of handicap indexes cycled across the generated roster.
HCP_POOL = [4.5, 9.4, 12.8, 7.2, 18.5, 15.0, 11.1, 20.2, 6.0, 14.0, 22.0, 8.3,
            16.7, 10.5, 3.1, 24.0]
# Two logins besides the TD, for cross-account / scorer poking if wanted.
MEMBER_LOGINS = ['cupmember1', 'cupmember2']


class Command(BaseCommand):
    help = "Build (or rebuild with --reset) the CupDemo tenant — a Triple Cup tournament for tee-box testing."

    def add_arguments(self, parser):
        parser.add_argument('--reset', action='store_true', default=False,
                            help='Tear down an existing CupDemo tenant and rebuild it.')
        parser.add_argument('--password', default=DEFAULT_PASSWORD,
                            help=f'Password for all logins (default: {DEFAULT_PASSWORD}).')
        parser.add_argument('--groups', type=int, default=3,
                            help='Number of foursomes / groups (2–6, default 3). '
                                 'Needs ≥2 to demo the tee-swap recovery.')

    @transaction.atomic
    def handle(self, *args, **options):
        self.password = options['password']
        groups = options['groups']
        if not 2 <= groups <= 6:
            raise CommandError('--groups must be between 2 and 6.')

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

        course, tee = self._create_course(account)
        reds, blues, td_player = self._create_roster(account, groups)

        self.stdout.write("Building Cup tournament (Triple Cup, draft locked)...")
        tourn = Tournament.objects.create(
            account=account, name='September Cup',
            start_date=timezone.now().date(), total_rounds=1,
            # The mobile tournament card shows the Cup actions when
            # active_games contains 'team_cup' (client-set in the real app).
            active_games=['team_cup'],
        )
        tt = TeamTournament.objects.create(
            tournament=tourn, cup_name='September Cup',
            players_per_team=len(reds), draft_complete=True,   # locked
        )
        team1 = TournamentTeam.objects.create(
            tournament=tt, name='Red', team_number=1, colour='red')
        team2 = TournamentTeam.objects.create(
            tournament=tt, name='Blue', team_number=2, colour='blue')
        team1.players.set(reds)
        team2.players.set(blues)

        # Single round, in-progress but UNSCORED (tee box).  is_cup_round is
        # true because it carries a RyderCupRoundConfig.
        rnd = Round.objects.create(
            account=account, course=course, status='in_progress',
            active_games=[], tournament=tourn, round_number=1,
            created_by=td_player, handicap_mode=HandicapMode.NET,
            net_percent=100, net_max_double_bogey=True,
        )
        rc = RyderCupRoundConfig.objects.create(
            round=rnd, tournament=tt,
            nassau_point_value=Decimal('1.00'), point_multiplier=Decimal('1.00'),
            round_format='triple_cup',
        )

        for g in range(groups):
            fs = Foursome.objects.create(
                round=rnd, group_number=g + 1,
                tee_time=time(hour=8, minute=g * 10),   # 8:00, 8:10, …
            )
            r_pair = reds[2 * g:2 * g + 2]
            b_pair = blues[2 * g:2 * g + 2]
            for p in (*r_pair, *b_pair):
                ch = p.course_handicap(tee)
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=tee,
                    course_handicap=ch, playing_handicap=ch,
                )
            RyderCupFoursomeConfig.objects.create(
                foursome=fs, round_config=rc, game_type=GameType.TRIPLE_CUP,
                team1=team1, team2=team2, point_value=4,
            )
            setup_triple_cup(
                fs,
                team1_ids=[r_pair[0].id, r_pair[1].id],
                team2_ids=[b_pair[0].id, b_pair[1].id],
                handicap_mode='net',
            )
            self.stdout.write(
                f"  Group {g + 1} @ 8:{g * 10:02d} — "
                f"{r_pair[0].name} & {r_pair[1].name} (Red) vs "
                f"{b_pair[0].name} & {b_pair[1].name} (Blue)")

        self._print_summary(account, groups)

    # -----------------------------------------------------------------------
    def _teardown(self, account):
        Round.objects.filter(account=account).delete()
        Tournament.objects.filter(account=account).delete()
        Player.objects.filter(account=account).delete()
        Course.objects.filter(account=account).delete()
        User.objects.filter(account=account).delete()
        account.delete()
        self.stdout.write(self.style.WARNING(f"  Tore down existing '{account.name}'."))

    def _create_course(self, account):
        course = Course.objects.create(account=account, name='Cup Ridge Golf Club')
        tee = Tee.objects.create(
            course=course, tee_name='White', slope=122,
            course_rating=Decimal('71.2'), par=72, holes=DEMO_HOLES,
        )
        self.stdout.write(f"  Created course: {course.name} ({tee.tee_name} tee)")
        return course, tee

    def _create_roster(self, account, groups):
        """Return (reds, blues, td_player): 2×groups per team, evenly split."""
        per_team = groups * 2
        reds, blues = [], []
        td_player = None
        for i in range(per_team * 2):
            team_is_red = (i % 2 == 0)
            idx = i // 2 + 1
            name = f"{'Red' if team_is_red else 'Blue'} {idx}"
            player = Player.objects.create(
                account=account, name=name,
                handicap_index=Decimal(str(HCP_POOL[i % len(HCP_POOL)])),
                sex=PlayerSex.MALE,
            )
            (reds if team_is_red else blues).append(player)

        # TD admin login attached to the first Red player; two member logins.
        td_player = reds[0]
        self._attach_login(account, td_player, 'cuptd', admin=True)
        member_targets = (blues[0], reds[1] if len(reds) > 1 else blues[1])
        for login, p in zip(MEMBER_LOGINS, member_targets):
            self._attach_login(account, p, login, admin=False)

        self.stdout.write(
            f"  Created {per_team * 2} players "
            f"({per_team} Red, {per_team} Blue); TD login 'cuptd'.")
        return reds, blues, td_player

    def _attach_login(self, account, player, username, *, admin):
        user = User.objects.create_user(
            username=username, password=self.password, account=account)
        user.email = f"{username}@cupdemo.golf"
        user.is_account_admin = admin
        user.save()
        Token.objects.get_or_create(user=user)
        player.user = user
        player.save(update_fields=['user'])

    def _print_summary(self, account, groups):
        self.stdout.write("")
        self.stdout.write(self.style.SUCCESS("=" * 64))
        self.stdout.write(self.style.SUCCESS("  CupDemo seeded — Triple Cup, draft locked, unscored"))
        self.stdout.write(self.style.SUCCESS("=" * 64))
        self.stdout.write(f"  Account name : {account.name}")
        self.stdout.write(f"  Players      : {Player.objects.filter(account=account).count()}")
        self.stdout.write(f"  Foursomes    : {groups} (2v2 Triple Cup, tee times 8:00…)")
        self.stdout.write("")
        self.stdout.write("  TD login (account name + username + password):")
        self.stdout.write(f"    {account.name} / cuptd / {self.password}   (admin)")
        self.stdout.write("")
        self.stdout.write("  Test the tee-box flow:")
        self.stdout.write("    Tournaments → September Cup → tap the round →")
        self.stdout.write("    ⋮ on a foursome card → Remove no-show / Swap tee position.")
        self.stdout.write("    Group 1 (earliest) removal is refused (no full group")
        self.stdout.write("    ahead to feed the phantom) — swap it later, then remove.")
        self.stdout.write("")
