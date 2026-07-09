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


class NassauNineRecalcTests(TestCase):
    """Nassau Nine registers under the 'nassau_nine' active-games key, so the
    score-submit recalc dispatch must fire calculate_nassau for it — otherwise
    the match never updates and the summary reads 'not started'."""

    def setUp(self):
        self.acct = Account.objects.create(name='Club9')
        self.user = User.objects.create_user(username='td9', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient(); self.client.force_authenticate(self.user)

        self.course = Course.objects.create(account=self.acct, name='Back9 GC')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, sex='M',
            sort_priority=0, holes=HOLES)
        # A back-nine Nassau Nine round: holes 10-18.
        self.round = Round.objects.create(
            account=self.acct, course=self.course, status='in_progress',
            active_games=['nassau_nine'], primary_game='nassau_nine',
            num_holes=9, starting_hole=10, bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.a = self._member('A')
        self.b = self._member('B')

    def _member(self, name):
        p = Player.objects.create(account=self.acct, name=name,
                                  handicap_index=Decimal('0.0'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=p, tee=self.tee,
            course_handicap=0, playing_handicap=0)
        return p

    def _submit(self, hole, a_gross, b_gross):
        return self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': hole,
             'scores': [{'player_id': self.a.id, 'gross_score': a_gross},
                        {'player_id': self.b.id, 'gross_score': b_gross}]},
            format='json')

    def test_score_submit_recalculates_the_single_match(self):
        # Setup the single match (no scores yet).
        r = self.client.post(
            reverse('api-nassau-setup', args=[self.fs.id]),
            {'team1_player_ids': [self.a.id], 'team2_player_ids': [self.b.id],
             'handicap_mode': 'gross', 'single_match': True},
            format='json')
        self.assertEqual(r.status_code, 201, r.data)

        # Play two back-nine holes THROUGH THE ENDPOINT (A wins both).
        self.assertEqual(self._submit(10, 3, 4).status_code, 200)
        self.assertEqual(self._submit(11, 3, 4).status_code, 200)

        # The recalc dispatch must have run calculate_nassau: the match rides the
        # 'front' bet and now shows 2 holes played, A 2 up — NOT "not started".
        from services.nassau import nassau_summary
        s = nassau_summary(self.fs)
        self.assertTrue(s['single_match'])
        self.assertEqual(s['front9']['holes_played'], 2, s['front9'])
        self.assertEqual(s['front9']['margin'], 2, s['front9'])
