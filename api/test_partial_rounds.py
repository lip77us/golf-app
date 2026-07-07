"""
api/test_partial_rounds.py
--------------------------
End-to-end backend behavior for partial rounds (Phase 2 of
docs/hole-flexibility.md): a 9-hole round completes on its 9 holes, not 18.
Grows as later sub-slices (per-hole scoring, handicap, segment games) land.
"""
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from decimal import Decimal

from accounts.models import Account
from api.views import RoundCompleteView
from core.models import Course, Player, Tee
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)

User = get_user_model()


class PartialRoundCompletionTests(TestCase):
    def _nine_hole_round(self):
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES[:9])
        r = make_round(course=course)
        r.num_holes = 9
        r.starting_hole = 1
        r.save()
        fs = make_foursome(r, [('Amy', 10), ('Bob', 12)])
        return r, fs

    def test_nine_hole_round_completes_on_nine(self):
        r, fs = self._nine_hole_round()
        # 8 of 9 holes scored -> not done.
        for h in range(1, 9):
            submit_hole(fs, h, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertFalse(RoundCompleteView._all_foursomes_done(r))
        # Score the 9th -> done (never needs holes 10-18).
        submit_hole(fs, 9, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertTrue(RoundCompleteView._all_foursomes_done(r))

    def test_expected_holes_is_the_nine_played(self):
        r, fs = self._nine_hole_round()
        self.assertEqual(RoundCompleteView._expected_holes(fs), set(range(1, 10)))


class RoundCreateHolesTests(TestCase):
    """The create endpoint persists num_holes/starting_hole and clamps them to
    the course size."""

    def setUp(self):
        self.account = Account.objects.create(name='Create Holes')
        self.user = User.objects.create_user(username='td', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _course(self, holes):
        """A course + tee owned by the test user's account (so create passes
        the account scope check)."""
        course = Course.objects.create(name='Create GC', account=self.account)
        Tee.objects.create(course=course, tee_name='White', slope=113,
                           course_rating=Decimal('72.0'), par=72, holes=holes)
        return course

    def _create(self, course, **extra):
        body = {'course_id': course.id, 'date': '2026-07-07',
                'active_games': ['low_net_round'], **extra}
        return self.client.post(reverse('api-round-create'), body, format='json')

    def test_defaults_are_full_18(self):
        resp = self._create(self._course(DEFAULT_HOLES))
        self.assertEqual(resp.status_code, 201)
        self.assertEqual((resp.data['num_holes'], resp.data['starting_hole']), (18, 1))

    def test_back_nine_persists(self):
        resp = self._create(self._course(DEFAULT_HOLES), num_holes=9, starting_hole=10)
        self.assertEqual((resp.data['num_holes'], resp.data['starting_hole']), (9, 10))

    def test_num_holes_clamped_to_short_course(self):
        resp = self._create(self._course(DEFAULT_HOLES[:9]), num_holes=18, starting_hole=1)
        self.assertEqual(resp.data['num_holes'], 9)   # clamped to the 9-hole course


class ClearScoreTests(TestCase):
    """gross_score=null clears (deletes) a HoleScore — the trailing-only Clear."""

    def setUp(self):
        from core.models import Tee
        from tournament.models import Round, Foursome, FoursomeMembership
        from scoring.models import HoleScore
        self.HoleScore = HoleScore
        self.account = Account.objects.create(name='Clear Test')
        self.user = User.objects.create_user(username='cs', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.course = Course.objects.create(name='CS GC', account=self.account)
        tee = Tee.objects.create(course=self.course, tee_name='White', slope=113,
                                 course_rating=Decimal('72.0'), par=72,
                                 holes=DEFAULT_HOLES)
        self.round = Round.objects.create(
            account=self.account, course=self.course, status='in_progress',
            active_games=['low_net_round'])
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.amy = Player.objects.create(account=self.account, name='Amy',
                                         handicap_index=Decimal('10.0'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=self.amy, tee=tee,
            course_handicap=10, playing_handicap=10)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-score-submit', args=[self.fs.id])

    def _submit(self, gross):
        return self.client.post(self.url, {
            'hole_number': 1,
            'scores': [{'player_id': self.amy.id, 'gross_score': gross}],
        }, format='json')

    def test_null_gross_clears_the_score(self):
        self.assertEqual(self._submit(5).status_code, 200)
        self.assertTrue(self.HoleScore.objects.filter(
            foursome=self.fs, player=self.amy, hole_number=1,
            gross_score__isnull=False).exists())
        # Clear it.
        self.assertEqual(self._submit(None).status_code, 200)
        self.assertFalse(self.HoleScore.objects.filter(
            foursome=self.fs, player=self.amy, hole_number=1).exists())


class LowNetHolesInPlayTests(TestCase):
    """The low-net block declares every hole the round plays (with pars) so the
    leaderboard strip can render not-yet-played holes as blanks — matching the
    score-entry card."""

    def test_summary_lists_all_holes_with_pars(self):
        from services.low_net_round import low_net_round_summary
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES)
        r = make_round(course=course, active_games=['low_net_round'])
        fs = make_foursome(r, [('Amy', 0), ('Bob', 0)])
        # Full 18-hole round with holes 10 & 11 left unplayed.
        for h in list(range(1, 10)) + list(range(12, 19)):
            submit_hole(fs, h, [(m.player_id, 4) for m in fs.memberships.all()])

        summ = low_net_round_summary(r)
        self.assertEqual(summ['holes_in_play'], list(range(1, 19)))
        # Par is available for the unplayed holes too (so they render, not vanish).
        self.assertIn(10, summ['hole_pars'])
        self.assertIn(11, summ['hole_pars'])


class BackNineCompletionTests(TestCase):
    def test_back_nine_completes_on_10_to_18(self):
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES)   # full 18-hole course
        r = make_round(course=course)
        r.num_holes = 9
        r.starting_hole = 10
        r.save()
        fs = make_foursome(r, [('Amy', 10), ('Bob', 12)])
        self.assertEqual(RoundCompleteView._expected_holes(fs), set(range(10, 19)))
        for h in range(10, 19):
            submit_hole(fs, h, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertTrue(RoundCompleteView._all_foursomes_done(r))
