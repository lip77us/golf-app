"""
api/test_nassau_segments.py
---------------------------
Per-segment Nassau bets: Front / Back / Overall can each be toggled, so an
Overall-only game is a straight 18-hole match. Gross mode keeps it simple.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership
from scoring.models import HoleScore

User = get_user_model()
HOLES = [{'number': i, 'par': 4, 'stroke_index': i} for i in range(1, 19)]


class NassauSegmentTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.client = APIClient(); self.client.force_authenticate(self.user)

        self.course = Course.objects.create(account=self.acct, name='Pines')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, sex='M',
            sort_priority=0, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=self.course, status='in_progress',
            active_games=['nassau'], bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        # A beats B on every hole (gross 4 vs 5) → A wins all segments.
        self.a = self._player('A', gross=4)
        self.b = self._player('B', gross=5)

    def _player(self, name, *, gross):
        p = Player.objects.create(account=self.acct, name=name,
                                  handicap_index=Decimal('0.0'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=p, tee=self.tee,
            course_handicap=0, playing_handicap=0)
        for h in range(1, 19):
            HoleScore.objects.create(foursome=self.fs, player=p,
                                     hole_number=h, gross_score=gross,
                                     handicap_strokes=0)
        return p

    def _setup(self, **body):
        body.setdefault('team1_player_ids', [self.a.id])
        body.setdefault('team2_player_ids', [self.b.id])
        body.setdefault('handicap_mode', 'gross')
        return self.client.post(
            reverse('api-nassau-setup', args=[self.fs.id]), body, format='json')

    def test_full_nassau_default(self):
        r = self._setup()
        self.assertEqual(r.status_code, 201, r.data)
        d = r.data
        self.assertTrue(d['play_front'] and d['play_back'] and d['play_overall'])
        # A swept all three segments.
        self.assertEqual(d['front9']['result'], 'team1')
        self.assertEqual(d['back9']['result'], 'team1')
        self.assertEqual(d['overall']['result'], 'team1')

    def test_overall_only_is_18_hole_match(self):
        r = self._setup(play_front=False, play_back=False, play_overall=True)
        self.assertEqual(r.status_code, 201, r.data)
        d = r.data
        self.assertFalse(d['play_front'])
        self.assertFalse(d['play_back'])
        self.assertTrue(d['play_overall'])
        # Only the Overall bet resolves; Front/Back never settle.
        self.assertIsNone(d['front9']['result'])
        self.assertIsNone(d['back9']['result'])
        self.assertEqual(d['overall']['result'], 'team1')

    def test_must_keep_at_least_one_bet(self):
        r = self._setup(play_front=False, play_back=False, play_overall=False)
        self.assertEqual(r.status_code, 400)
