"""
management command: seed_eclectic
---------------------------------
Builds a standalone **multi-round individual tournament** for testing
Eclectic — WITHOUT touching the App-Store-reviewer `seed_demo` tenant or the
`seed_cup_demo` one.

Creates ONE tenant ("EclecticDemo") with:
  * A TD admin login + two member logins (phone-verified, so the app's
    phone-first flow works locally)
  * 12 golfers over 3 foursomes, handicaps spread from scratch to 24 so the
    gross and net pools rank DIFFERENTLY — which is the whole reason there
    are two of them
  * **Two courses with different pars on four holes**, so the rule the game
    turns on is visible: a 4 on Ridgeview's par-5 5th is a birdie and beats a
    par 4 on Harbour Links' par-4 5th
  * A 3-round stroke-play tournament with the Stroke Play championship AND
    Eclectic (both pools, $10 each), rounds 1 and 2 CLOSED and round 3 live
    at ten holes

Why it is left mid-round
------------------------
Everything interesting about the board is only true while a round is open: the
`R3 live · projected` chip, the italic prize, the `–` on holes nobody has
reached, and the lock screen's `Improved on N` line — which by rule never fires
in round 1. Closing round 3 is one command away (printed below) when you want
to see the final state instead.

Usage
-----
    python manage.py seed_eclectic                 # build (errors if it exists)
    python manage.py seed_eclectic --reset         # tear down + rebuild
    python manage.py seed_eclectic --reset --password 'MyPass1'
    python manage.py seed_eclectic --reset --thru 18   # finish round 3 too

Sibling of `seed_cup_demo` — same idioms.
"""
from datetime import timedelta
from decimal import Decimal
import random

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone
from rest_framework.authtoken.models import Token

from accounts.models import Account
from core.models import (Course, HandicapMode, Player, PlayerSex, RoundStatus,
                         Tee)
from games.models import EclecticConfig, LowNetChampionshipConfig
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round, Tournament

User = get_user_model()

ACCOUNT_NAME = 'EclecticDemo'
DEFAULT_PASSWORD = 'HalvedEclectic2026'

TD_PHONE = '+13105550301'
MEMBER_LOGINS = ['ecmember1', 'ecmember2']
MEMBER_PHONES = ['+13105550302', '+13105550303']

# Par-72. Hole 1 is SI 7 so stroke order isn't trivially hole == SI.
HARBOUR_HOLES = [
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

#: Ridgeview: par 71, and FOUR holes play differently. The 5th is a five where
#: Harbour's is a four (so a 4 there is a birdie that beats a par), the 7th is
#: a four where Harbour's is a three, and the 13th and 17th come back the other
#: way. Its stroke index is its own, which is what the Net pool's "per round,
#: on that course's index" rule exists for.
_RIDGE_PAR = {5: 5, 7: 4, 13: 4, 17: 4}
RIDGE_HOLES = [
    {**h,
     'par': _RIDGE_PAR.get(h['number'], h['par']),
     'stroke_index': ((h['stroke_index'] + 6) % 18) + 1,
     'yards': h['yards'] + (40 if h['number'] in _RIDGE_PAR else -15)}
    for h in HARBOUR_HOLES
]

#: **The late arrival** — he plays the final round only, which is the case the
#: packet names: "a golfer can have holes with no candidates (missed rounds
#: plus a live round); show those as `–`". Nothing else in this seed produces
#: one, because two complete rounds cover all eighteen hole numbers between
#: them. He is in group 1, so he is easy to find on the board.
MISSED_BY = 'Dee Oyelaran'
MISSED_ROUNDS = (1, 2)

ROSTER = [
    ('Alan Prescott',   0.8), ('Bea Nakamura',    4.2),
    ('Cal Whitlock',    7.5), ('Dee Oyelaran',   10.1),
    ('Eli Marchetti',  12.4), ('Fay Brennan',    14.0),
    ('Gus Halvorsen',  16.3), ('Hana Ito',       18.7),
    ('Ivan Delgado',   20.5), ('Jo Ashworth',    22.1),
    ('Kit Romero',     23.4), ('Lou Farraday',   24.0),
]


class Command(BaseCommand):
    help = ("Build (or rebuild with --reset) the EclecticDemo tenant — a "
            "3-round, 2-course individual tournament with Eclectic on.")

    def add_arguments(self, parser):
        parser.add_argument('--reset', action='store_true', default=False,
                            help='Tear down an existing EclecticDemo and rebuild.')
        parser.add_argument('--password', default=DEFAULT_PASSWORD)
        parser.add_argument('--thru', type=int, default=10,
                            help='Holes scored in the LIVE final round (1–18, '
                                 'default 10). Pass 18 to close the event.')
        parser.add_argument('--seed', type=int, default=20260926,
                            help='RNG seed — the scores are random but '
                                 'REPRODUCIBLE, so a bug you see is a bug you '
                                 'can show somebody else.')

    @transaction.atomic
    def handle(self, *args, **options):
        self.password = options['password']
        thru = options['thru']
        if not 1 <= thru <= 18:
            raise CommandError('--thru must be between 1 and 18.')
        self.rng = random.Random(options['seed'])

        existing = Account.objects.filter(name__iexact=ACCOUNT_NAME).first()
        if existing:
            if not options['reset']:
                raise CommandError(
                    f"Account '{ACCOUNT_NAME}' already exists. "
                    f"Pass --reset to tear it down and rebuild.")
            self._teardown(existing)

        account = Account.objects.create(name=ACCOUNT_NAME)
        self.stdout.write(f'Created account: {account.name}')

        harbour, h_tee = self._course(
            account, 'Harbour Links', 72, HARBOUR_HOLES, Decimal('71.4'))
        ridge, r_tee = self._course(
            account, 'Ridgeview Golf Club', 71, RIDGE_HOLES, Decimal('70.8'))

        players = self._roster(account)

        today = timezone.now().date()
        tourn = Tournament.objects.create(
            account=account, name='Autumn Three-Day',
            start_date=today - timedelta(days=2), total_rounds=3,
            active_games=['low_net', 'eclectic'],
            scoring_method='stroke',
            handicap_mode=HandicapMode.NET, net_percent=100,
        )
        LowNetChampionshipConfig.objects.create(
            tournament=tourn, entry_fee=Decimal('20.00'),
            payouts=[{'place': 1, 'amount': 120.00},
                     {'place': 2, 'amount': 70.00},
                     {'place': 3, 'amount': 50.00}])
        EclecticConfig.objects.create(
            tournament=tourn,
            gross_on=True, net_on=True,
            gross_entry_fee=Decimal('10.00'),
            gross_payouts=[{'place': 1, 'amount': 80.00},
                           {'place': 2, 'amount': 40.00}],
            net_entry_fee=Decimal('10.00'),
            net_payouts=[{'place': 1, 'amount': 80.00},
                         {'place': 2, 'amount': 40.00}])

        # Harbour, Ridgeview, Harbour — so one course is played twice, which is
        # what exercises the "keep the EARLIER round on a tie" rule.
        plan = [
            (1, harbour, h_tee, today - timedelta(days=2), 18),
            (2, ridge,   r_tee, today - timedelta(days=1), 18),
            (3, harbour, h_tee, today,                     thru),
        ]
        for number, course, tee, date, holes in plan:
            self._round(account, tourn, players, number, course, tee, date,
                        holes)

        self._summary(account, tourn, thru)

    # -----------------------------------------------------------------------
    def _teardown(self, account):
        HoleScore.objects.filter(foursome__round__account=account).delete()
        Round.objects.filter(account=account).delete()
        Tournament.objects.filter(account=account).delete()
        Player.objects.filter(account=account).delete()
        Course.objects.filter(account=account).delete()
        User.objects.filter(account=account).delete()
        account.delete()
        self.stdout.write(
            self.style.WARNING(f"  Tore down existing '{account.name}'."))

    def _course(self, account, name, par, holes, rating):
        course = Course.objects.create(account=account, name=name)
        tee = Tee.objects.create(
            course=course, tee_name='White', slope=124,
            course_rating=rating, par=par, holes=holes)
        self.stdout.write(f'  Course: {name} (par {par})')
        return course, tee

    def _roster(self, account):
        players = []
        for name, idx in ROSTER:
            players.append(Player.objects.create(
                account=account, name=name,
                handicap_index=Decimal(str(idx)), sex=PlayerSex.MALE))
        self._login(account, players[0], 'ectd', admin=True, phone=TD_PHONE)
        for login, p, phone in zip(MEMBER_LOGINS, players[1:3], MEMBER_PHONES):
            self._login(account, p, login, admin=False, phone=phone)
        self.stdout.write(f'  Roster: {len(players)} golfers, '
                          f'{ROSTER[0][1]} to {ROSTER[-1][1]}')
        return players

    def _login(self, account, player, username, *, admin, phone):
        user = User.objects.create_user(
            username=username, password=self.password, account=account)
        user.email = f'{username}@eclecticdemo.golf'
        user.is_account_admin = admin
        user.phone = phone
        user.phone_verified_at = timezone.now()
        user.save()
        Token.objects.get_or_create(user=user)
        player.user = user
        player.phone = phone
        player.save(update_fields=['user', 'phone'])

    def _round(self, account, tourn, players, number, course, tee, date, holes):
        rnd = Round.objects.create(
            account=account, course=course, date=date,
            status=(RoundStatus.COMPLETE if holes >= 18
                    else RoundStatus.IN_PROGRESS),
            active_games=[], tournament=tourn, round_number=number,
            created_by=players[0],
            handicap_mode=HandicapMode.NET, net_percent=100,
            net_max_double_bogey=True, num_holes=18,
        )
        pars = {h['number']: h['par'] for h in tee.holes}
        sis  = {h['number']: h['stroke_index'] for h in tee.holes}

        for g in range(len(players) // 4):
            fs = Foursome.objects.create(round=rnd, group_number=g + 1)
            group = players[g * 4:(g + 1) * 4]
            for p in group:
                # **One golfer misses round 2**, which is the case the packet
                # states and nothing else here would exercise: he stays
                # eligible with one fewer score to choose from on every hole,
                # and any hole he has no candidate for at all reads `–` on the
                # Best row rather than counting as level.
                if number in MISSED_ROUNDS and p.name == MISSED_BY:
                    continue
                ch = p.course_handicap(tee)
                m = FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=tee,
                    course_handicap=ch, playing_handicap=ch)
                self._score(m, pars, sis, holes)
        self.stdout.write(
            f'  R{number} {course.name} — {holes} holes '
            f'({"closed" if holes >= 18 else "LIVE"})')

    def _score(self, membership, pars, sis, holes):
        """A plausible card: better golfers make more pars.

        The spread is deliberate — a scratch golfer and a 24 must not produce
        the same board in both pools, or the two pools are one game drawn
        twice.
        """
        hcp = membership.playing_handicap or 0
        for h in range(1, holes + 1):
            par = pars[h]
            # Strokes over par rise with handicap, with real variance so a good
            # hole from a poor golfer can still win a hole number outright.
            #
            # **Tuned for the CARD, not for the round.** A first pass produced
            # believable round totals (77 to 108 off 0.8 to 24) on a 4% birdie
            # rate — and an eclectic built from that is almost all pars and
            # bogeys, which shows none of the notation the card exists to draw.
            # The low handicaps birdie more here, and an eagle is possible on a
            # par 5, so the finished card carries circles and the odd double.
            outcomes = [-2, -1, 0, 1, 2, 3]
            weights  = [
                (2 if par == 5 and hcp <= 12 else 0),   # eagle, par 5s only
                max(2, 16 - hcp // 2),
                34,
                20 + hcp,
                5 + hcp,
                1 + hcp // 2,
            ]
            base = self.rng.choices(outcomes, weights=weights)[0]
            gross = max(1, par + base)
            strokes = membership.handicap_strokes_on_hole(sis[h])
            hs = HoleScore(
                foursome=membership.foursome, player=membership.player,
                hole_number=h, gross_score=gross, handicap_strokes=strokes)
            hs.save()

    # -----------------------------------------------------------------------
    def _summary(self, account, tourn, thru):
        from services.eclectic import eclectic_standings
        w = self.stdout.write
        w('')
        w(self.style.SUCCESS('=' * 66))
        w(self.style.SUCCESS('  EclecticDemo seeded — 3 rounds, 2 courses, '
                             'Eclectic gross + net'))
        w(self.style.SUCCESS('=' * 66))
        w(f'  Account      : {account.name}')
        w(f'  Tournament   : {tourn.name}')
        w(f'  Golfers      : {Player.objects.filter(account=account).count()} '
          f'(3 foursomes)')
        w(f'  Rounds       : R1 Harbour Links · R2 Ridgeview · R3 Harbour '
          f'({thru} holes{"" if thru >= 18 else ", LIVE"})')
        w('')
        w('  Login — PHONE. **There is no other way in.** Password login was')
        w('  retired: LoginView 403s unless PASSWORD_LOGIN_ENABLED is set, and')
        w('  the password screen is gone from the app. The username and')
        w('  password below exist only for a shell or the Django admin.')
        w(f'    {TD_PHONE}   (TD, admin, verified)')
        w(f'    {MEMBER_PHONES[0]}   (member)')
        w('    In dev the code prints in the runserver console AND comes back')
        w('    as `debug_code`. Watch OTP_REQUESTS_PER_HOUR (5 per number):')
        w("      PhoneOTP.objects.filter(phone='...').delete()")
        w('')
        w('  Point the app at THIS server, or it will look for the tenant on')
        w('  Railway and not find it:')
        w('    flutter run --dart-define=USE_LOCAL=true')
        w(f'    (shell / admin only: {account.name} / ectd / {self.password})')
        w('')
        for pool in ('gross', 'net'):
            rows = eclectic_standings(tourn, pool)[:3]
            w(f'  Eclectic {pool:<5} leaders: ' + ', '.join(
                f"{r['player_name'].split()[0]} "
                f"{'+' if (r['total'] or 0) > 0 else ''}{r['total']}"
                for r in rows))
        w('')
        w('  What to look at:')
        w('    Tournaments → Autumn Three-Day → Leaderboard → Eclectic tab.')
        w('      · the Gross/Net switch, each segment carrying its own pool')
        if thru < 18:
            w('      · `R3 live · projected` in amber, and the prize in italic')
        else:
            w('      · the event is CLOSED — no chip, and the prize upright')
        w('      · tap a row to open the card; tap it again to close it')
        w('      · Ridgeview is par 71 — holes 5, 7, 13 and 17 play a')
        w('        different par there, which is the rule the game turns on')
        w('      · Net shows the same gross digits with that round\'s dots')
        w(f'      · {MISSED_BY} arrived for R3 only — still ranked, on one')
        w('        round\'s scores rather than three')
        if thru < 18:
            w('        (and the eight holes R3 has not reached read `–` on')
            w('        his Best row)')
        w('    ⚙ → Configure Eclectic for the setup screen.')
        w('    Settle up → By game for `Eclectic · Gross` and `· Net`.')
        w('')
        # The minimum-holes rule, shown working. This seed is what surfaced
        # the need for it: before the 26 Sep ruling the late arrival came out
        # T3 on −2 from TEN holes, level with a golfer who had played
        # fifty-four, because missing holes add nothing to the total.
        rows = eclectic_standings(tourn, 'gross')
        short = [r for r in rows if 0 < r['holes_kept'] < 18]
        if short:
            w('  The minimum-holes rule, working:')
            for r in short:
                w(f"    {r['player_name']} is "
                  f"{'T' if r['tied'] else ''}{r['rank']} of {len(rows)} on "
                  f"{r['total']:+d} from {r['holes_kept']} of 18 holes — "
                  f"below every whole card, and not paid.")
            w('    His scores are real and stay on the board; the row carries')
            w(f"    `{short[0]['holes_kept']} OF 18` so the empty money column")
            w('    has a reason on it.')
            w('')

        if thru < 18:
            w('  To see the FINAL state (no chip, upright prize, and the')
            w('  lock screen naming both pools):')
            w(self.style.WARNING(
                '    python manage.py seed_eclectic --reset --thru 18'))
        w('')
