"""
management command: seed_road_trip
----------------------------------
Builds a standalone **multi-round Road Trip** for testing — WITHOUT touching
the App-Store-reviewer `seed_demo` tenant, `seed_cup_demo` or `seed_eclectic`.

Creates ONE tenant ("RoadTripDemo") with:
  * A TD admin login + two member logins (phone-verified, so the app's
    phone-first flow works locally)
  * 8 golfers over 2 foursomes, indexes from 4.2 to 22.0
  * **Six Irish links courses with three different pars**, which is what the
    trip's to-par scoring exists for: ten courses with ten pars cannot be
    compared on raw totals
  * A 6-round trip counting the **best 4**, Net and Gross both on, rounds 1–4
    closed, round 5 live and round 6 not yet played
  * One golfer in each of the board's three sections, and a mid-trip index cut

The three sections, and who is in them
--------------------------------------
The board has `ranked`, `qualifying` and `ineligible`, and the difference
between the last two is the only part that cannot be read off a scorecard —
so the seed puts a real golfer in each rather than leaving two of them empty:

  * **Ranked** — six golfers with five rounds in, so each of them DROPS one.
    That is the headline rule and it is only visible once somebody has more
    rounds than count: an earlier cut of this seed closed four rounds, every
    ranked golfer counted all four, and best-4-of-6 drew as though it were
    every-round-counts.
  * **Still qualifying** — Mark Dolan sat out rounds 3 and 5. He has three of
    his four and is out on the course in round 6, which is his last chance.
  * **Not eligible** — Paul Reilly played the first round and went home. One
    round plus the one still being played is two, and the trip counts four.

Niamh Kelly is the story the HCP CUT badge exists for: she is a 19.3 playing
like a 12, netted under par in all three of the opening rounds, and was cut to
16.0 from round 4. The adjustment is a real `RoadTripIndexAdjustment`, so
rounds 4 onward are scored off the cut index and rounds 1–3 keep the handicap
they were played with — which is the rule the whole log exists to hold.

Why it is left mid-round
------------------------
`pending` cells, the provisional chip and the "needs 1 more round" line are
only true while a round is open. Closing round 5 is one command away (printed
below) when you want to see the settled board instead.

Usage
-----
    python manage.py seed_road_trip                 # build (errors if it exists)
    python manage.py seed_road_trip --reset         # tear down + rebuild
    python manage.py seed_road_trip --reset --thru 18   # finish round 5 too

Sibling of `seed_eclectic` — same idioms.
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
from games.models import RoadTripConfig, RoadTripIndexAdjustment
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round, Tournament

User = get_user_model()

ACCOUNT_NAME = 'RoadTripDemo'
DEFAULT_PASSWORD = 'HalvedRoadTrip2026'

TD_PHONE = '+13105550401'
MEMBER_LOGINS = ['rtmember1', 'rtmember2']
MEMBER_PHONES = ['+13105550402', '+13105550403']

#: A par-72 shape. Hole 1 is SI 7 so stroke order isn't trivially hole == SI.
BASE_HOLES = [
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

#: The trip, from the handoff packet's own Irish sample. **Three different
#: pars across six courses** — the reason the trip scores to par and not to
#: strokes. `shift` rotates the stroke index so each course ranks its own
#: holes, which is what the per-round net allocation is read off.
COURSES = [
    # name,                 par, rating,  slope, shift
    ('Royal County Down',    71, '74.1',  141, 0),
    ('Royal Portrush',       72, '74.8',  138, 5),
    ('Portstewart',          72, '73.9',  136, 9),
    ('Portmarnock',          72, '74.0',  134, 2),
    ('Lahinch',              72, '73.2',  133, 13),
    ('Ballybunion',          71, '74.3',  139, 7),
]

#: `skill` is how well the golfer actually plays, and it is deliberately NOT
#: his index. For seven of them the two agree within a shot; for Niamh they do
#: not, which is what produces a real reason for the cut rather than a badge
#: with nothing behind it.
#:
#: `misses` are 1-based round numbers.
ROSTER = [
    # name,            index, skill, misses
    ('Aoife Byrne',      8.4,   9,   []),
    ('Ciarán Walsh',    12.1,  13,   []),
    ('Declan Murphy',    4.2,   5,   []),
    ('Mark Dolan',      15.6,  16,   [3, 5]),
    ('Niamh Kelly',     19.3,  12,   []),
    ('Seán O’Brien',     6.8,   7,   []),
    ('Tom Hughes',      10.5,  11,   []),
    ('Paul Reilly',     22.0,  23,   [2, 3, 4, 5, 6]),
]

CUT_GOLFER = 'Niamh Kelly'
CUT_FROM_ROUND = 4
CUT_INDEX = Decimal('16.0')
CUT_REASON = 'Net under par in all three of the opening rounds'

TOTAL_ROUNDS = 6
ROUNDS_TO_COUNT = 4
#: Rounds 1–5 are closed and 6 is live. That split is what puts a golfer in
#: each of the board's three sections AND gives every ranked golfer a dropped
#: round — see the module docstring.
LIVE_ROUND = 6


class Command(BaseCommand):
    help = ("Build (or rebuild with --reset) the RoadTripDemo tenant — a "
            "6-round, 6-course Road Trip counting the best 4.")

    def add_arguments(self, parser):
        parser.add_argument('--reset', action='store_true', default=False,
                            help='Tear down an existing RoadTripDemo and rebuild.')
        parser.add_argument('--password', default=DEFAULT_PASSWORD)
        parser.add_argument('--thru', type=int, default=11,
                            help='Holes scored in the LIVE final round (1–18, '
                                 'default 11). Pass 18 to close the trip.')
        parser.add_argument('--seed', type=int, default=20260929,
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

        courses = [self._course(account, *c) for c in COURSES]
        players = self._roster(account)
        by_name = {p.name: p for p in players}
        self.skill = {p.id: s for p, (_, _, s, _) in zip(players, ROSTER)}
        self.misses = {p.id: set(m) for p, (_, _, _, m) in zip(players, ROSTER)}

        today = timezone.now().date()
        tourn = Tournament.objects.create(
            account=account, name='Irish Links Trip',
            start_date=today - timedelta(days=4),
            total_rounds=TOTAL_ROUNDS, rounds_to_count=ROUNDS_TO_COUNT,
            active_games=['road_trip'],
            scoring_method='stroke',
            handicap_mode=HandicapMode.NET, net_percent=100,
        )
        RoadTripConfig.objects.create(
            tournament=tourn,
            net_on=True, gross_on=True,
            handicap_mode=RoadTripConfig.UPDATED,
            net_max_double_bogey=True, gross_max_double_bogey=False)

        # **The cut is created BEFORE any round is built**, so every round
        # from 4 on is scored off it by `index_for` — the same call the app
        # makes. Creating it afterwards would leave a badge on the board with
        # handicaps behind it that never saw the adjustment.
        RoadTripIndexAdjustment.objects.create(
            tournament=tourn, player=by_name[CUT_GOLFER],
            from_round_number=CUT_FROM_ROUND,
            handicap_index=CUT_INDEX, reason=CUT_REASON)

        for number, (course, tee) in enumerate(courses, start=1):
            if number < LIVE_ROUND:
                holes = 18
            elif number == LIVE_ROUND:
                holes = thru
            else:
                holes = 0
            self._round(account, tourn, players, number, course, tee,
                        today - timedelta(days=TOTAL_ROUNDS - number), holes)

        from services.road_trip import capture_starting_indexes
        capture_starting_indexes(tourn)

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

    def _course(self, account, name, par, rating, slope, shift):
        holes = [
            {**h,
             'stroke_index': ((h['stroke_index'] - 1 + shift) % 18) + 1,
             # A par 71 gives back the 17th.
             'par': 4 if (par == 71 and h['number'] == 17) else h['par']}
            for h in BASE_HOLES
        ]
        course = Course.objects.create(account=account, name=name)
        tee = Tee.objects.create(
            course=course, tee_name='Championship', slope=slope,
            course_rating=Decimal(rating), par=par, holes=holes)
        self.stdout.write(f'  Course: {name} (par {par}, {slope} slope)')
        return course, tee

    def _roster(self, account):
        players = []
        for name, idx, _skill, _miss in ROSTER:
            players.append(Player.objects.create(
                account=account, name=name,
                handicap_index=Decimal(str(idx)), sex=PlayerSex.MALE))
        self._login(account, players[0], 'rttd', admin=True, phone=TD_PHONE)
        for login, p, phone in zip(MEMBER_LOGINS, players[1:3], MEMBER_PHONES):
            self._login(account, p, login, admin=False, phone=phone)
        indexes = [r[1] for r in ROSTER]
        self.stdout.write(f'  Roster: {len(players)} golfers, '
                          f'{min(indexes)} to {max(indexes)}')
        return players

    def _login(self, account, player, username, *, admin, phone):
        user = User.objects.create_user(
            username=username, password=self.password, account=account)
        user.email = f'{username}@roadtripdemo.golf'
        user.is_account_admin = admin
        user.phone = phone
        user.phone_verified_at = timezone.now()
        user.save()
        Token.objects.get_or_create(user=user)
        player.user = user
        player.phone = phone
        player.save(update_fields=['user', 'phone'])

    def _round(self, account, tourn, players, number, course, tee, date, holes):
        from services.road_trip import course_handicap, index_for

        rnd = Round.objects.create(
            account=account, course=course, date=date,
            status=(RoundStatus.COMPLETE if holes >= 18
                    else RoundStatus.IN_PROGRESS if holes
                    else RoundStatus.PENDING),
            active_games=[], tournament=tourn, round_number=number,
            created_by=players[0],
            handicap_mode=HandicapMode.NET, net_percent=100,
            net_max_double_bogey=True, num_holes=18,
        )
        pars = {h['number']: h['par'] for h in tee.holes}
        sis = {h['number']: h['stroke_index'] for h in tee.holes}

        for g in range(len(players) // 4):
            group = players[g * 4:(g + 1) * 4]
            if all(number in self.misses[p.id] for p in group):
                continue
            fs = Foursome.objects.create(round=rnd, group_number=g + 1)
            for p in group:
                if number in self.misses[p.id]:
                    continue
                # The trip's own handicap, from the trip's own log — the
                # override is what `apply_indexes` writes, and writing the
                # same three fields here is what keeps the hub's CH · PH from
                # showing a number the golfer is not playing off.
                ch = course_handicap(index_for(tourn, p, number), tee)
                m = FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=tee,
                    playing_handicap_override=ch,
                    course_handicap=ch, playing_handicap=ch)
                if holes:
                    self._score(m, pars, sis, holes, tee)
        state = ('closed' if holes >= 18
                 else f'LIVE, {holes} holes' if holes else 'not played')
        self.stdout.write(f'  R{number} {course.name} — {state}')

    def _score(self, membership, pars, sis, holes, tee):
        """A plausible card, built to a TARGET round score.

        The target comes from `skill`, not from the index, and that separation
        is the seed's one real trick: it is what lets a golfer play better than
        his index for three rounds and get cut for it, which is the state the
        HCP CUT badge reports.

        **The target is a course handicap off the skill index**, plus the few
        shots almost nobody gives back — so a golfer shoots roughly what a man
        of that ability shoots on a course of that rating. A first pass drew
        per-hole outcomes from handicap-weighted odds instead and produced
        Niamh at fourteen under par net per round: believable-looking cards
        whose relationship to the strokes being received was nothing at all.
        The net figure is the thing this whole board is ranked on, so it is
        the thing worth calibrating.
        """
        from services.road_trip import course_handicap

        skill = self.skill[membership.player_id]
        target = course_handicap(Decimal(str(skill)), tee) \
            + self.rng.gauss(3.0, 3.5)
        target = max(-2, int(round(target)))

        # Birdies first — a better golfer makes more of them, and each one
        # buys back a stroke that has to be dropped somewhere else. Without
        # them a high target is 18 holes of bogeys and doubles, which is a
        # card nobody recognises.
        over = {h: 0 for h in range(1, holes + 1)}
        n_birdies = max(0, int(round(self.rng.gauss(3.5 - skill / 7.0, 1.0))))
        for h in self.rng.sample(list(over), min(n_birdies, len(over))):
            # An eagle is possible on a par 5, for a golfer who can reach it.
            over[h] = -2 if (pars[h] == 5 and skill <= 10
                             and self.rng.random() < 0.15) else -1
            target -= over[h]

        # Then spend the budget, harder holes first by weight, nothing worse
        # than a triple.
        holes_list = list(over)
        weights = [19 - sis[h] for h in holes_list]
        spent = 0
        # A very high target on a short card can run out of room; stop rather
        # than spin. (18 holes x 3 is the ceiling, which only a 40-handicap on
        # a full round would reach.)
        while spent < target and any(v < 3 for v in over.values()):
            h = self.rng.choices(holes_list, weights=weights)[0]
            if over[h] >= 3:
                continue
            over[h] += 1
            spent += 1

        for h in range(1, holes + 1):
            gross = max(1, pars[h] + over[h])
            strokes = membership.handicap_strokes_on_hole(sis[h])
            HoleScore(
                foursome=membership.foursome, player=membership.player,
                hole_number=h, gross_score=gross,
                handicap_strokes=strokes).save()

    # -----------------------------------------------------------------------
    def _summary(self, account, tourn, thru):
        from services.road_trip import road_trip_standings
        w = self.stdout.write
        w('')
        w(self.style.SUCCESS('=' * 68))
        w(self.style.SUCCESS('  RoadTripDemo seeded — 6 rounds, 6 courses, '
                             'best 4 to count'))
        w(self.style.SUCCESS('=' * 68))
        w(f'  Account      : {account.name}')
        w(f'  Tournament   : {tourn.name}   ({tourn.counting_rule_label})')
        w(f'  Golfers      : {Player.objects.filter(account=account).count()} '
          f'(2 foursomes)')
        w(f'  Rounds       : R1–R5 closed · R6 LIVE ({thru} holes)')
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
        w('')
        for title in ('net', 'gross'):
            st = road_trip_standings(tourn, title)
            if not st:
                continue
            lead = ', '.join(
                f"{r['name'].split()[0]} "
                f"{'+' if (r['total'] or 0) > 0 else ''}{r['total']}"
                for r in st['ranked'][:3])
            w(f"  {title.title():<5} leaders: {lead}")
        w('')
        st = road_trip_standings(tourn, 'net')
        w('  The three sections, each with somebody real in it:')
        w(f"    ranked      {len(st['ranked'])} — five rounds in, worst one dropped")
        for r in st['qualifying']:
            w(f"    qualifying  {r['name']} — {r['played']} of "
              f"{st['counts']}, needs {r['needs']} more")
        for r in st['ineligible']:
            w(f"    ineligible  {r['name']} — {r['played']} round(s) and "
              f"not enough left to reach {st['counts']}")
        w('')
        cut = [r for r in (st['ranked'] + st['qualifying'] + st['ineligible'])
               if r.get('adjusted')]
        if cut:
            a = cut[0]['adjusted']
            w('  The HCP CUT, with the rounds behind it:')
            w(f"    {cut[0]['name']} → {a['index']} from R{a['from_round']}")
            w(f"    “{a['reason']}”")
            w('    Rounds 1–3 keep the handicap they were played off; 4 on')
            w('    are scored off the cut. That is the rule the log exists')
            w('    for, and the board draws it as a badge on her row.')
            w('')
        w('  What to look at:')
        w('    Tournaments → Irish Links Trip → Leaderboard → Road Trip tab.')
        w('      · the Net/Gross switch — each title picks its OWN best four,')
        w('        so a golfer\'s counted set can differ between them')
        w('      · counted vs dropped cells, and `–` where a round was missed')
        w('      · R6 cells read as pending while the round is open')
        w('      · the HCP CUT badge, with the reason under the strip')
        w('    Tournament card → Rounds for the per-round side games.')
        w('    Tournament card → Players for the index list and the adjust')
        w('      sheet (a reason is required — it is shown to the group).')
        w('')
        if thru < 18:
            w('  To see the settled board, with the trip finished:')
            w(self.style.WARNING(
                '    python manage.py seed_road_trip --reset --thru 18'))
        w('')
