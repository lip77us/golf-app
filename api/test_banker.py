"""
api/test_banker.py
------------------
The Banker endpoints. The engine is covered by
`scoring/tests/test_banker.py`; what is pinned here is the thing an endpoint
can get wrong on its own — **the sequence holds however the call arrives**,
not only when the UI behaves.

A declaration that lands too late is a 409, not a 400: the request was well
formed and the world moved. That distinction is what lets a client tell "you
mistyped" from "somebody already teed off".
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round

User = get_user_model()

HOLES = [{'number': n, 'par': 3 if n == 3 else 4, 'stroke_index': n,
          'yards': 400} for n in range(1, 19)]


class BankerEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Banker Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Sequoyah')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['banker'], primary_game='banker',
            bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('0'))
            for n in ('Paul', 'Dave', 'Sam', 'Lee')
        ]
        for p in self.players:
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        self.pid = {p.name: p.id for p in self.players}
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    # -- urls ----------------------------------------------------------------

    def _setup_url(self):
        return reverse('api-banker-setup', args=[self.fs.id])

    def _hole_url(self):
        return reverse('api-banker-hole', args=[self.fs.id])

    def _setup(self, **over):
        body = {'first_banker_id': self.pid['Paul'], 'min_bet': 5,
                'max_bet': 50}
        body.update(over)
        return self.client.post(self._setup_url(), body, format='json')

    def _declare(self, **body):
        body.setdefault('hole_number', 1)
        return self.client.post(self._hole_url(), body, format='json')

    def _score(self, hole, **scores):
        for name, val in scores.items():
            HoleScore.objects.update_or_create(
                foursome=self.fs, player_id=self.pid[name],
                hole_number=hole, defaults={'gross_score': val})

    # -- setup ---------------------------------------------------------------

    def test_setup_opens_the_first_hole_with_its_banker(self):
        res = self._setup()
        self.assertEqual(res.status_code, 201)
        self.assertEqual(res.data['current_hole'], 1)
        self.assertEqual(res.data['current']['banker_id'], self.pid['Paul'])
        self.assertEqual(res.data['min_bet'], Decimal('5.00'))

    def test_setup_is_idempotent(self):
        """Nothing about a RESULT is stored, so a re-setup re-scores rather
        than double-counting."""
        self._setup()
        self._declare(max_bet=10, bets=[{'player_id': self.pid['Dave'],
                                         'amount': 10}])
        res = self._setup(max_bet=40)
        self.assertEqual(res.status_code, 201)
        self.assertEqual(res.data['max_bet'], Decimal('40.00'))

    def test_the_first_banker_has_to_be_in_the_group(self):
        stranger = Player.objects.create(account=self.acct, name='Outsider',
                                         handicap_index=Decimal('9'))
        res = self._setup(first_banker_id=stranger.id)
        self.assertEqual(res.status_code, 400)

    def test_strokes_off_is_refused_by_the_serializer(self):
        res = self._setup(handicap_mode='strokes_off')
        self.assertEqual(res.status_code, 400)

    # -- the sequence, enforced server-side ----------------------------------

    def test_a_bet_before_the_maximum_is_refused(self):
        self._setup()
        res = self._declare(bets=[{'player_id': self.pid['Dave'],
                                   'amount': 10}])
        self.assertEqual(res.status_code, 400)
        self.assertIn('maximum', res.data['detail'])

    def test_a_bet_above_the_bankers_maximum_is_refused(self):
        self._setup()
        self._declare(max_bet=20)
        res = self._declare(bets=[{'player_id': self.pid['Dave'],
                                   'amount': 30}])
        self.assertEqual(res.status_code, 400)

    def test_the_lock_needs_every_opponent_in(self):
        self._setup()
        self._declare(max_bet=20, bets=[{'player_id': self.pid['Dave'],
                                         'amount': 10}])
        res = self._declare(lock=True)
        self.assertEqual(res.status_code, 400)

    def test_a_declaration_after_the_lock_is_a_conflict_not_a_bad_request(self):
        """The request was well formed and arrived too late — a client has to
        be able to tell that from a typo."""
        self._setup()
        self._declare(max_bet=20, bets=[
            {'player_id': self.pid['Dave'], 'amount': 10},
            {'player_id': self.pid['Sam'],  'amount': 10},
            {'player_id': self.pid['Lee'],  'amount': 10}])
        self.assertEqual(self._declare(lock=True).status_code, 200)
        res = self._declare(bets=[{'player_id': self.pid['Dave'],
                                   'amount': 20}])
        self.assertEqual(res.status_code, 409)

    def test_doubles_land_and_the_counter_takes_all_three(self):
        self._setup()
        self._declare(max_bet=20, bets=[
            {'player_id': self.pid['Dave'], 'amount': 10},
            {'player_id': self.pid['Sam'],  'amount': 10},
            {'player_id': self.pid['Lee'],  'amount': 10}], lock=True)
        self._declare(double=self.pid['Dave'])
        res = self._declare(counter=True)
        lines = {l['player_id']: l for l in res.data['current']['lines']}
        self.assertEqual(lines[self.pid['Dave']]['stake'], Decimal('40'))
        self.assertEqual(lines[self.pid['Sam']]['stake'], Decimal('20'))

    def test_a_double_after_the_first_score_is_a_conflict(self):
        self._setup()
        self._declare(max_bet=20, bets=[
            {'player_id': self.pid['Dave'], 'amount': 10},
            {'player_id': self.pid['Sam'],  'amount': 10},
            {'player_id': self.pid['Lee'],  'amount': 10}], lock=True)
        self._score(1, Sam=4)
        res = self._declare(double=self.pid['Dave'])
        self.assertEqual(res.status_code, 409)

    # -- advancing -----------------------------------------------------------

    def test_advance_hands_the_bank_to_the_low_net(self):
        self._setup()
        self._declare(max_bet=20, bets=[
            {'player_id': self.pid['Dave'], 'amount': 10},
            {'player_id': self.pid['Sam'],  'amount': 10},
            {'player_id': self.pid['Lee'],  'amount': 10}], lock=True)
        self._score(1, Paul=5, Dave=4, Sam=5, Lee=5)
        res = self.client.post(reverse('api-banker-advance', args=[self.fs.id]),
                               {'after_hole': 1}, format='json')
        self.assertEqual(res.status_code, 201)
        self.assertEqual(res.data['current']['banker_id'], self.pid['Dave'])

    def test_a_tie_refuses_to_advance_until_the_group_answers(self):
        self._setup()
        self._declare(max_bet=20, bets=[
            {'player_id': self.pid['Dave'], 'amount': 10},
            {'player_id': self.pid['Sam'],  'amount': 10},
            {'player_id': self.pid['Lee'],  'amount': 10}], lock=True)
        self._score(1, Paul=5, Dave=4, Sam=4, Lee=5)

        board = self.client.get(reverse('api-banker', args=[self.fs.id]))
        self.assertEqual(board.data['awaiting_tie'], 1)

        url = reverse('api-banker-advance', args=[self.fs.id])
        self.assertEqual(self.client.post(url, {'after_hole': 1},
                                          format='json').status_code, 400)
        res = self.client.post(url, {'after_hole': 1,
                                     'banker_id': self.pid['Sam'],
                                     'tie_reason': 'holed_first'},
                               format='json')
        self.assertEqual(res.status_code, 201)
        self.assertEqual(res.data['current']['banker_id'], self.pid['Sam'])

    # -- reading -------------------------------------------------------------

    def test_the_result_view_404s_before_setup(self):
        res = self.client.get(reverse('api-banker', args=[self.fs.id]))
        self.assertEqual(res.status_code, 404)

    def test_settlement_itemises_the_holes_he_banked(self):
        self._setup()
        self._declare(max_bet=20, bets=[
            {'player_id': self.pid['Dave'], 'amount': 10},
            {'player_id': self.pid['Sam'],  'amount': 10},
            {'player_id': self.pid['Lee'],  'amount': 10}], lock=True)
        self._score(1, Paul=6, Dave=4, Sam=4, Lee=4)
        res = self.client.get(reverse('api-banker-settlement',
                                      args=[self.fs.id]))
        self.assertEqual(res.status_code, 200)
        paul = next(p for p in res.data['players']
                    if p['player_id'] == self.pid['Paul'])
        self.assertEqual(len(paul['holes_banked'][0]['lines']), 3)
        self.assertEqual(paul['total'], Decimal('-30'))

    def test_the_leaderboard_carries_the_game(self):
        self._setup()
        res = self.client.get(reverse('api-leaderboard', args=[self.round.id]))
        self.assertEqual(res.status_code, 200)
        self.assertIn('banker', res.data['games'])

    def test_a_foursome_in_another_account_is_a_404(self):
        other = Account.objects.create(name='Elsewhere')
        stranger = User.objects.create_user(username='x', account=other)
        self.client.force_authenticate(stranger)
        self.assertEqual(self._setup().status_code, 404)
