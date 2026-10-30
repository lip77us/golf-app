"""
api/test_side_game_stake.py
---------------------------
A side game's stake must not move the primary game's.

Reproduced first: on a finished $10 Annandale Friday, the $5 ante a Skins pool
setup wrote to the round cut a golfer's settled Nassau from +$60 to +$30.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from services.annandale_friday import annandale_friday_summary
from services.honors import honors_summary
from services.skins import skins_summary
from tournament.models import Round, Foursome, FoursomeMembership

User = get_user_model()
HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class SideGameStakeTests(TestCase):
    def setUp(self):
        acct = Account.objects.create(name='A')
        user = User.objects.create_user(username='td', account=acct)
        self.c = APIClient()
        self.c.force_authenticate(user)
        course = Course.objects.create(account=acct, name='C')
        tee = Tee.objects.create(
            course=course, tee_name='W', slope=113,
            course_rating=Decimal('72'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=acct, course=course, status='in_progress',
            active_games=['annandale_friday', 'skins', 'honors'],
            primary_game='annandale_friday', bet_unit=Decimal('10'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.ids = []
        for n in 'ABCDEF':
            p = Player.objects.create(account=acct, name=n, handicap_index=0)
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=tee,
                course_handicap=0, playing_handicap=0)
            self.ids.append(p.id)
        i = self.ids
        r = self.c.post(
            reverse('api-annandale-friday-setup', args=[self.fs.id]),
            {'teams': [i[:2], i[2:4], i[4:]], 'handicap_mode': 'gross',
             'auto_press': False}, format='json')
        assert r.status_code == 201, r.content
        for h in range(1, 19):
            self.c.post(reverse('api-score-submit', args=[self.fs.id]),
                        {'hole_number': h, 'scores': [
                            {'player_id': p, 'gross_score': g} for p, g in
                            zip(i, (3, 5, 4, 6, 5, 7))]}, format='json')

    def _fresh(self):
        return Foursome.objects.get(id=self.fs.id)

    def _nassau_net(self):
        return annandale_friday_summary(self._fresh())['players'][0]['net']

    def test_a_skins_pool_ante_leaves_the_nassau_alone(self):
        before = self._nassau_net()
        r = self.c.post(reverse('api-skins-setup', args=[self.fs.id]),
                        {'payout_style': 'pool', 'pool_ante': '5.00',
                         'handicap_mode': 'gross'}, format='json')
        assert r.status_code in (200, 201), r.content
        assert self._nassau_net() == before == 60
        money = skins_summary(self._fresh())['money']
        assert money['bet_unit'] == 5
        assert money['pool'] == 30
        assert Round.objects.get(id=self.round.id).bet_unit == 10

    def test_a_skins_pool_with_no_ante_still_reads_the_round(self):
        # Rounds set up before this, and Skins as the round's own game.
        self.c.post(reverse('api-skins-setup', args=[self.fs.id]),
                    {'payout_style': 'pool', 'handicap_mode': 'gross'},
                    format='json')
        assert skins_summary(self._fresh())['money']['bet_unit'] == 10

    def test_honors_has_its_own_stake(self):
        before = self._nassau_net()
        r = self.c.post(reverse('api-honors-setup', args=[self.fs.id]),
                        {'stake': '2.00', 'handicap_mode': 'gross'},
                        format='json')
        assert r.status_code in (200, 201), r.content
        s = honors_summary(self._fresh())
        assert s['money']['bet_unit'] == 2
        assert self._nassau_net() == before == 60

    def test_honors_money_is_priced_on_its_own_stake(self):
        self.c.post(reverse('api-honors-setup', args=[self.fs.id]),
                    {'stake': '2.00', 'handicap_mode': 'gross',
                     'per_point_mode': 'first'}, format='json')
        s = honors_summary(self._fresh())
        rates = [abs(p['money']) for p in s['players'] if p['money']]
        assert rates, s['players']
        # All 18 holes held by one golfer, $2 a point, from each of five.
        assert max(rates) == 18 * 2 * 5, s['players']
