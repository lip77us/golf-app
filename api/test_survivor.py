"""
api/test_survivor.py
--------------------
Survivor setup / result endpoints round-trip through the
serializer/view/urls, plus the recalc dispatch and the leaderboard block.
(The horse-race math is covered by scoring/tests/test_survivor.py.)
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Round, Foursome, FoursomeMembership

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class SurvivorEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Survivor Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['survivor'], primary_game='survivor',
            bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('0'))
            for n in ('A', 'B', 'C')
        ]
        for p in self.players:
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.ids = [p.id for p in self.players]

    def _submit(self, hole, scores):
        for pid, gross in scores:
            HoleScore.objects.update_or_create(
                foursome=self.fs, player_id=pid, hole_number=hole,
                defaults={'gross_score': gross, 'handicap_strokes': 0})

    def _setup(self, **over):
        body = {'handicap_mode': 'gross'}
        body.update(over)
        return self.client.post(
            reverse('api-survivor-setup', args=[self.fs.id]), body,
            format='json')

    # ── Setup / result ───────────────────────────────────────────────────────

    def test_setup_returns_summary(self):
        resp = self._setup()
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['handicap']['mode'], 'gross')
        self.assertEqual(resp.data['status'], 'pending')
        self.assertEqual(resp.data['money']['bet_unit'], 5.0)
        self.assertEqual(resp.data['money']['pot'], 15.0)       # three entries
        self.assertEqual(resp.data['money']['max_liability'], 45.0)   # 9 × $5
        self.assertEqual(resp.data['current']['role'], 'elimination')

    def test_setup_defaults_to_net(self):
        resp = self.client.post(
            reverse('api-survivor-setup', args=[self.fs.id]), {},
            format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['handicap']['mode'], 'net')
        self.assertEqual(resp.data['handicap']['net_percent'], 100)

    def test_setup_scores_existing_holes_and_result_mirrors(self):
        A, B, C = self.ids
        self._submit(1, [(A, 4), (B, 5), (C, 6)])       # C eliminated
        self._submit(2, [(A, 4), (B, 5), (C, 4)])       # A wins the Survivor
        resp = self._setup()
        self.assertEqual(resp.status_code, 201, resp.data)
        money = {p['player_id']: p['money'] for p in resp.data['players']}
        self.assertEqual(money, {A: 10.0, B: -5.0, C: -5.0})

        got = self.client.get(reverse('api-survivor-result', args=[self.fs.id]))
        self.assertEqual(got.status_code, 200)
        self.assertEqual(
            {p['player_id']: p['money'] for p in got.data['players']}, money)

    def test_setup_is_idempotent(self):
        A, B, C = self.ids
        self._submit(1, [(A, 4), (B, 5), (C, 6)])
        self._setup()
        resp = self._setup(handicap_mode='net', net_percent=90)
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['handicap']['mode'], 'net')
        self.assertEqual(resp.data['handicap']['net_percent'], 90)
        # One game row, and the existing score is still reflected.
        self.assertEqual(len(resp.data['survivors']), 1)

    def test_rejects_a_bad_handicap_mode(self):
        resp = self._setup(handicap_mode='stableford')
        self.assertEqual(resp.status_code, 400, resp.data)

    # ── Recalc on score submission ───────────────────────────────────────────

    def test_submitting_a_score_recalculates(self):
        A, B, C = self.ids
        self._setup()
        url = reverse('api-score-submit', args=[self.fs.id])
        for hole, scores in ((1, (4, 5, 6)), (2, (4, 5, 4))):
            resp = self.client.post(url, {
                'hole_number': hole,
                'scores': [{'player_id': pid, 'gross_score': g}
                           for pid, g in zip(self.ids, scores)],
            }, format='json')
            self.assertIn(resp.status_code, (200, 201), resp.data)

        got = self.client.get(reverse('api-survivor-result', args=[self.fs.id]))
        legs = got.data['survivors']
        self.assertEqual(len(legs), 1, legs)
        self.assertEqual(legs[0]['winner_id'], A)
        self.assertEqual(legs[0]['outcome'], 'won')

    # ── Leaderboard block ────────────────────────────────────────────────────

    def test_leaderboard_carries_a_survivor_block(self):
        A, B, C = self.ids
        self._submit(1, [(A, 4), (B, 5), (C, 6)])
        self._submit(2, [(A, 4), (B, 5), (C, 4)])
        self._setup()
        resp = self.client.get(
            reverse('api-leaderboard', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200, resp.data)
        block = resp.data['games']['survivor']
        self.assertEqual(block['label'], 'Survivor')
        summary = block['by_group'][0]['summary']
        self.assertEqual(block['by_group'][0]['foursome_id'], self.fs.id)
        self.assertEqual(summary['survivors'][0]['winner_id'], A)
        # The shared scorecard grid block rides along for the leaderboard card.
        self.assertEqual(len(summary['scorecard']['holes']), 18)
        self.assertEqual(summary['scorecard']['holes_in_play'],
                         list(range(1, 19)))

    # ── Wiring / auth ────────────────────────────────────────────────────────

    def test_configured_games_reports_survivor(self):
        self._setup()
        resp = self.client.get(reverse('api-round-detail', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200, resp.data)
        fs = next(f for f in resp.data['foursomes'] if f['id'] == self.fs.id)
        self.assertIn('survivor', fs['configured_games'])

    def test_result_before_setup_is_an_empty_summary(self):
        resp = self.client.get(reverse('api-survivor-result', args=[self.fs.id]))
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['status'], 'pending')
        self.assertEqual(resp.data['survivors'], [])
        self.assertEqual(resp.data['players'], [])

    def test_requires_auth(self):
        anon = APIClient()
        resp = anon.get(reverse('api-survivor-result', args=[self.fs.id]))
        self.assertIn(resp.status_code, (401, 403))

    def test_foreign_foursome_is_not_reachable(self):
        other_acct = Account.objects.create(name='Someone Else')
        other = User.objects.create_user(username='other', account=other_acct)
        client = APIClient()
        client.force_authenticate(other)
        resp = client.get(reverse('api-survivor-result', args=[self.fs.id]))
        self.assertEqual(resp.status_code, 404)
