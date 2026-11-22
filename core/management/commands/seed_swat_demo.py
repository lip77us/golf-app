"""
python manage.py seed_swat_demo [--phone +1510…] [--holes 6] [--reset]

Builds an Oakmont SWAT tournament for a LOCAL account so the feature can be
tested in the simulator without clicking through the wizard: 14 golfers (the
account's own golfer first, then the next lowest-id roster golfers), dealt in
snake order into four teams (two threesomes), the phantom order drawn, and
--holes holes of believable gross scores entered for everybody.

Defaults to the developer's own login (+15102823126). Never run against
production: it writes a tournament and scores. --reset removes the previous
"SWAT Demo" first.
"""
import random

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

DEMO_NAME = 'SWAT Demo'


class Command(BaseCommand):
    help = 'Seed a 14-golfer Oakmont SWAT tournament for a local account.'

    def add_arguments(self, parser):
        parser.add_argument('--phone', default='+15102823126')
        parser.add_argument('--holes', type=int, default=6,
                            help='holes of scores to enter (0-18)')
        parser.add_argument('--golfers', type=int, default=14)
        parser.add_argument('--reset', action='store_true')

    @transaction.atomic
    def handle(self, *args, **o):
        from datetime import date
        from accounts.models import User
        from core.models import Player, Tee
        from scoring.models import HoleScore
        from services import swat
        from tournament.models import Round, Tournament

        user = User.objects.filter(phone=o['phone']).first()
        if user is None:
            raise CommandError(f'No local user with phone {o["phone"]}.')
        account = user.account

        if o['reset']:
            n, _ = Tournament.objects.filter(account=account,
                                             name=DEMO_NAME).delete()
            self.stdout.write(f'Removed {n} previous demo object(s).')

        me = Player.objects.filter(user=user).first()
        roster = list(Player.objects.filter(account=account, is_phantom=False)
                      .exclude(pk=getattr(me, 'pk', None))
                      .order_by('id'))
        want = o['golfers']
        golfers = ([me] if me else []) + roster
        golfers = golfers[:want]
        if len(golfers) < 12:
            raise CommandError('Need at least 12 golfers on the roster.')

        tee = (Tee.objects.filter(course__account=account, superseded_by=None)
               .exclude(holes=[]).order_by('id').first())
        if tee is None:
            raise CommandError('No course with a tee and hole data.')

        t = Tournament.objects.create(
            account=account, name=DEMO_NAME, start_date=date.today(),
            total_rounds=1, active_games=[], scoring_method='stroke',
            handicap_mode='net', net_percent=100)
        rnd = Round.objects.create(
            account=account, course=tee.course, tournament=t, round_number=1,
            status='in_progress', active_games=[], num_holes=18,
            created_by=me)
        swat.setup_swat(rnd, stake=6, allow_fivesomes=False)

        ids = [g.pk for g in golfers]
        dealt = swat.preview_teams(ids)
        teams = [[p['id'] for p in tm['players']] for tm in dealt['teams']]
        swat.apply_teams(rnd, teams, {pid: tee.pk for pid in ids})

        holes = max(0, min(18, o['holes']))
        if holes:
            self._scores(rnd, tee, holes)

        self.stdout.write(self.style.SUCCESS(
            f'SWAT Demo ready: tournament {t.pk}, round {rnd.pk}, '
            f'{len(golfers)} golfers, {len(teams)} teams, {holes} holes scored.'))
        for i, tm in enumerate(dealt['teams'], 1):
            names = ', '.join(p['name'] for p in tm['players'])
            tag = ' (threesome + phantom)' if tm['three'] else ''
            self.stdout.write(f'  Team {i}: {tm["name"]}{tag}: {names}')
        self.stdout.write(f'Watch link token: {rnd.watch_token}')

    def _scores(self, rnd, tee, holes):
        """Gross scores around par, worse with a higher index, seeded so a
        re-run reproduces the same round. Every group gets the same holes."""
        from scoring.models import HoleScore
        rng = random.Random(54)
        par = {int(h['number']): int(h['par']) for h in tee.holes}
        for fs in rnd.foursomes.all():
            for m in fs.memberships.select_related('player'):
                hi = float(m.player.handicap_index or 0)
                for h in range(1, holes + 1):
                    x = rng.random()
                    over = hi / 18
                    v = par[h] + (-1 if x < max(.02, .13 - hi * .006) else 0) \
                        + (1 if x > 1 - over * .55 else 0) \
                        + (1 if x > 1 - over * .16 else 0)
                    HoleScore.objects.update_or_create(
                        foursome=fs, player=m.player, hole_number=h,
                        defaults={'gross_score': max(par[h] - 1, v),
                                  'handicap_strokes': 0})
