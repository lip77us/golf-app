"""
api/test_triple_nassau.py
-------------------------
Triple Nassau setup / result / press endpoints round-trip through the
serializer/view/urls, plus the leaderboard block.  (The scoring engine +
pairwise allocation are covered by scoring/tests/test_triple_nassau.py.)
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership

from scoring.tests._helpers import submit_hole

User = get_user_model()

# Real stroke indexes so the pairwise allocation has somewhere to land.
HOLES = [
    {'number': 1, 'par': 4, 'stroke_index': 7,  'yards': 400},
    {'number': 2, 'par': 4, 'stroke_index': 3,  'yards': 410},
    {'number': 3, 'par': 3, 'stroke_index': 15, 'yards': 175},
    {'number': 4, 'par': 5, 'stroke_index': 9,  'yards': 520},
    {'number': 5, 'par': 4, 'stroke_index': 1,  'yards': 440},
    {'number': 6, 'par': 4, 'stroke_index': 13, 'yards': 380},
    {'number': 7, 'par': 3, 'stroke_index': 17, 'yards': 165},
    {'number': 8, 'par': 5, 'stroke_index': 11, 'yards': 540},
    {'number': 9, 'par': 4, 'stroke_index': 5,  'yards': 420},
    {'number': 10, 'par': 4, 'stroke_index': 8,  'yards': 395},
    {'number': 11, 'par': 4, 'stroke_index': 4,  'yards': 415},
    {'number': 12, 'par': 3, 'stroke_index': 16, 'yards': 170},
    {'number': 13, 'par': 5, 'stroke_index': 10, 'yards': 530},
    {'number': 14, 'par': 4, 'stroke_index': 2,  'yards': 445},
    {'number': 15, 'par': 4, 'stroke_index': 14, 'yards': 385},
    {'number': 16, 'par': 3, 'stroke_index': 18, 'yards': 160},
    {'number': 17, 'par': 5, 'stroke_index': 12, 'yards': 535},
    {'number': 18, 'par': 4, 'stroke_index': 6,  'yards': 425},
]


class TripleNassauEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Triple Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['triple_nassau'], bet_unit=Decimal('10.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = {}
        for name, hcp in (('Ann', 0), ('Ben', 5), ('Cal', 15)):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal(str(hcp)))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=hcp, playing_handicap=hcp)
            self.players[name] = p
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.ids = [self.players[n].id for n in ('Ann', 'Ben', 'Cal')]

    def _setup(self, **over):
        body = {'player_ids': self.ids, 'handicap_mode': 'gross',
                'net_percent': 100, 'press_mode': 'none'}
        body.update(over)
        return self.client.post(
            reverse('api-triple-nassau-setup', args=[self.fs.id]),
            body, format='json')

    def test_setup_creates_three_matches_and_returns_summary(self):
        r = self._setup(handicap_mode='strokes_off')
        assert r.status_code == 201, r.content
        s = r.json()
        assert len(s['matches']) == 3
        assert [p['player_id'] for p in s['players']] == self.ids
        # bet_unit override flows to the round.
        r2 = self._setup(bet_unit='7.50')
        assert r2.status_code == 201
        self.round.refresh_from_db()
        assert self.round.bet_unit == Decimal('7.50')

    def test_result_and_settlement_after_scores(self):
        A, B, C = (self.players[n].id for n in ('Ann', 'Ben', 'Cal'))
        for h in range(1, 19):
            submit_hole(self.fs, h, [(A, 3), (B, 4), (C, 5)])  # gross sweep
        assert self._setup().status_code == 201  # calculates over the scores

        r = self.client.get(reverse('api-triple-nassau-result', args=[self.fs.id]))
        assert r.status_code == 200
        nets = {p['short_name']: p['net'] for p in r.json()['players']}
        # Ann sweeps both (+$60), Ben splits (0), Cal loses both (−$60).
        assert nets[self.players['Ann'].short_name] == 60.0, nets
        assert nets[self.players['Ben'].short_name] == 0.0, nets
        assert nets[self.players['Cal'].short_name] == -60.0, nets
        assert abs(sum(nets.values())) < 1e-9

    def test_leaderboard_has_triple_nassau_block(self):
        self._setup()
        submit_hole(self.fs, 1, [(self.players['Ann'].id, 3),
                                 (self.players['Ben'].id, 4),
                                 (self.players['Cal'].id, 5)])
        self._setup()  # recalc
        r = self.client.get(reverse('api-leaderboard', args=[self.round.id]))
        assert r.status_code == 200, r.content
        games = r.json().get('games', {})
        assert 'triple_nassau' in games, list(games.keys())
        block = games['triple_nassau']
        assert block['by_group'][0]['summary']['matches']

    def test_result_404_when_not_configured(self):
        r = self.client.get(reverse('api-triple-nassau-result', args=[self.fs.id]))
        assert r.status_code == 404
