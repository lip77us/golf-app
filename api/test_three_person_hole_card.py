"""The three-man Mini Singles card: by GET and with the save."""
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from django.contrib.auth import get_user_model
from django.test import TestCase

from scoring.tests._helpers import make_foursome, make_round, make_tee, submit_hole
from services.three_person_match import (
    setup_three_person_match, calculate_three_person_match,
)

User = get_user_model()


class ThreePersonHoleCardEndpointTests(TestCase):
    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['match_play'])
        self.acct = self.round.account
        self.fs = make_foursome(
            self.round, [('Ann', 4), ('Ben', 9), ('Cal', 14)], tee=self.tee)
        self.ids = [m.player_id for m in self.fs.memberships.all()]
        setup_three_person_match(self.fs)
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _get(self, hole):
        return self.client.get(
            reverse('api-three-person-hole', args=[self.fs.id, hole]))

    def test_the_get_returns_the_card(self):
        c = self._get(1).json()
        assert c['hole'] == 1 and c['phase'] == 'points'
        assert [p['player_id'] for p in c['players']] == self.ids

    def test_the_save_carries_the_card(self):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': 1,
             'scores': [{'player_id': p, 'gross_score': g}
                        for p, g in zip(self.ids, (4, 5, 6))]},
            format='json')
        assert r.status_code in (200, 201), r.content
        c = r.json()['three_person_hole']
        assert c['hole_complete'] and c == self._get(1).json()

    def test_no_game_is_an_empty_card(self):
        from games.models import ThreePersonMatch
        ThreePersonMatch.objects.all().delete()
        assert self._get(1).json() == {}

    def test_a_stranger_gets_a_404(self):
        other = Account.objects.create(name='Other')
        u = User.objects.create_user(username='x', account=other)
        cl = APIClient()
        cl.force_authenticate(u)
        assert cl.get(reverse('api-three-person-hole',
                              args=[self.fs.id, 1])).status_code == 404


class TheBoardHasOneTabTests(ThreePersonHoleCardEndpointTests):
    """A group of three is one Mini Singles tab, not a bracket tab that says
    "not set up yet" beside the real one."""

    def test_the_empty_bracket_tab_is_gone_and_the_real_one_is_named(self):
        r = self.client.get(
            reverse('api-leaderboard', args=[self.round.id])).json()
        assert 'match_play' not in r['active_games'], r['active_games']
        assert 'three_person_match' in r['active_games']
        assert r['games']['three_person_match']['label'] == 'Mini Singles'
