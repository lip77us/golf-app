"""The solo score-entry card: by GET and with the save."""
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from games.models import SoloGame
from scoring.tests._helpers import make_foursome, make_round, make_tee
from services.solo import setup_solo

User = get_user_model()


class SoloHoleCardEndpointTests(TestCase):
    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['solo_nassau'])
        self.fs = make_foursome(self.round, [('Ann', 10)], tee=self.tee)
        self.pid = self.fs.memberships.first().player_id
        setup_solo(self.round, variant=SoloGame.Variant.NASSAU)
        self.user = User.objects.create_user(
            username='td', account=self.round.account)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _get(self, hole):
        return self.client.get(
            reverse('api-solo-hole', args=[self.fs.id, hole]))

    def test_the_get_returns_the_card(self):
        c = self._get(1).json()
        assert c['hole'] == 1 and c['variant'] == 'nassau'
        assert c['golfer']['first'] == 'Ann'

    def test_the_save_carries_the_card(self):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': 1,
             'scores': [{'player_id': self.pid, 'gross_score': 4}]},
            format='json')
        assert r.status_code in (200, 201), r.content
        c = r.json()['solo_hole']
        assert c['hole_complete'] and c == self._get(1).json()

    def test_a_stranger_gets_a_404(self):
        other = Account.objects.create(name='Other')
        u = User.objects.create_user(username='x', account=other)
        cl = APIClient()
        cl.force_authenticate(u)
        assert cl.get(reverse('api-solo-hole',
                              args=[self.fs.id, 1])).status_code == 404
