"""
api/test_pink_ball_legacy_name.py
---------------------------------
Migration games/0067 renamed PinkBallConfig.ball_color to game_name: the app
stopped asking what colour the ball was and started asking what the group
CALLS the game.  Builds shipped before that rename still speak the old key,
and they keep working against this backend until every one of them is gone.

Pins both halves of that promise:

  * write — a legacy POST carrying 'ball_color' saves a name instead of a 400
  * read  — the GET echoes 'ball_color' so an old build's
            `data['ball_color'] as String? ?? 'Pink'` shows the real name
            rather than silently renaming every group's game to "Pink"

Plus the rule the alias must not weaken: a request naming the game NEITHER way
is still rejected.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from games.models import PinkBallConfig
from tournament.models import Round, Foursome, FoursomeMembership

from scoring.tests._helpers import DEFAULT_HOLES

User = get_user_model()


class PinkBallLegacyNameTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.course = Course.objects.create(account=self.acct, name='Tilden')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=DEFAULT_HOLES,
        )
        self.round = Round.objects.create(
            account=self.acct, course=self.course, status='in_progress',
        )
        fs = Foursome.objects.create(round=self.round, group_number=1)
        for i in range(4):
            p = Player.objects.create(
                account=self.acct, name=f'P{i}', handicap_index=10)
            FoursomeMembership.objects.create(
                foursome=fs, player=p, tee=self.tee,
                course_handicap=10, playing_handicap=10)

        self.api = APIClient()
        self.api.force_authenticate(self.user)
        self.url = reverse('api-pink-ball-setup', args=[self.round.id])

    def test_legacy_ball_color_saves_the_name(self):
        """An old build's POST must not 400 on the required game_name."""
        r = self.api.post(self.url, {'ball_color': 'Green Ball'}, format='json')
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data['ball_color'], 'Green Ball')
        self.assertEqual(
            PinkBallConfig.objects.get(round=self.round).game_name,
            'Green Ball')

    def test_get_echoes_ball_color_for_old_builds(self):
        self.api.post(self.url, {'game_name': 'Blue Ball'}, format='json')
        data = self.api.get(self.url).data
        self.assertEqual(data['game_name'],  'Blue Ball')
        self.assertEqual(data['ball_color'], 'Blue Ball')

    def test_current_key_still_wins(self):
        """Both keys present — the real field is authoritative."""
        self.api.post(self.url,
                      {'game_name': 'Gold Ball', 'ball_color': 'stale'},
                      format='json')
        self.assertEqual(
            PinkBallConfig.objects.get(round=self.round).game_name, 'Gold Ball')

    def test_neither_key_is_still_rejected(self):
        """The alias must not smuggle in a nameless game."""
        r = self.api.post(self.url, {'entry_fee': '10.00'}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('game_name', r.data)
