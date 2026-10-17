"""
api/test_round_handicap_basis.py
--------------------------------
`GET/POST/DELETE /api/rounds/{id}/handicap-basis/` — setting the basis from
the screen where players are assigned to tees.

This is the CASUAL path as much as the tournament one, which is the whole
reason the default lives on the course.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round, Tournament

User = get_user_model()


def _holes():
    return [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 320}
            for n in range(1, 19)]


class RoundHandicapBasisTests(TestCase):

    def setUp(self):
        self.account = Account.objects.create(name='Basis Round Acct')
        self.user = User.objects.create_user(username='td', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        self.course = Course.objects.create(account=self.account, name='Tilden Park')
        self.m_white = Tee.objects.create(
            course=self.course, tee_name='White', sex='M', par=70,
            course_rating=Decimal('69.0'), slope=122, holes=_holes())
        self.w_red = Tee.objects.create(
            course=self.course, tee_name='RED', sex='W', par=71,
            course_rating=Decimal('71.5'), slope=125, holes=_holes())
        # A casual round: no tournament at all.
        self.round = Round.objects.create(
            account=self.account, course=self.course,
            round_number=1, date=date(2026, 10, 17))
        self.url = reverse('api-round-handicap-basis', args=[self.round.id])

    # ------------------------------------------------------------ reading

    def test_unset_reports_no_source(self):
        r = self.client.get(self.url)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIsNone(r.data['basis'])
        self.assertIsNone(r.data['source'])
        self.assertEqual(r.data['course_name'], 'Tilden Park')

    def test_it_offers_the_tees_on_this_round_s_course(self):
        other = Course.objects.create(account=self.account, name='Metropolitan')
        Tee.objects.create(course=other, tee_name='Blue', sex='M', par=71,
                           course_rating=Decimal('70.1'), slope=120, holes=_holes())
        ids = {c['tee_id'] for c in self.client.get(self.url).data['candidates']}
        self.assertEqual(ids, {self.m_white.id, self.w_red.id})

    # ------------------------------------------------------------ writing

    def test_setting_it_and_remembering_on_the_course(self):
        r = self.client.post(self.url, {'tee_id': self.m_white.id}, format='json')
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data['basis']['tee_id'], self.m_white.id)
        self.assertEqual(r.data['source'], 'round')
        self.course.refresh_from_db()
        self.assertEqual(self.course.default_basis_tee_id, self.m_white.id,
                         'the next round here should not need setting')

    def test_the_course_default_alone_is_reported_as_the_course_s(self):
        self.course.default_basis_tee = self.m_white
        self.course.save(update_fields=['default_basis_tee'])
        r = self.client.get(self.url)
        self.assertEqual(r.data['basis']['tee_id'], self.m_white.id)
        self.assertEqual(r.data['source'], 'course',
                         'a TD asks WHY this is the basis when it surprises him')

    def test_a_tournament_basis_is_named_as_such(self):
        tour = Tournament.objects.create(account=self.account, name='Cup',
                                         start_date=date(2026, 10, 8),
                                         handicap_basis_tee=self.m_white)
        self.round.tournament = tour
        self.round.save(update_fields=['tournament'])
        self.assertEqual(self.client.get(self.url).data['source'], 'tournament')

    def test_clearing_falls_back_to_the_course(self):
        self.course.default_basis_tee = self.w_red
        self.course.save(update_fields=['default_basis_tee'])
        self.client.post(self.url, {'tee_id': self.m_white.id,
                                    'remember_on_course': False}, format='json')
        r = self.client.delete(self.url, format='json')
        self.assertEqual(r.data['basis']['tee_id'], self.w_red.id)
        self.assertEqual(r.data['source'], 'course')

    def test_a_foreign_tee_is_refused(self):
        other = Course.objects.create(account=self.account, name='Metropolitan')
        foreign = Tee.objects.create(
            course=other, tee_name='Blue', sex='M', par=71,
            course_rating=Decimal('70.1'), slope=120, holes=_holes())
        r = self.client.post(self.url, {'tee_id': foreign.id}, format='json')
        self.assertEqual(r.status_code, 400)

    # ------------------------------------------------------------ the lock

    def _tee_off(self):
        """One real gross score, which is what closes the door."""
        p = Player.objects.create(account=self.account, name='A Golfer',
                                  short_name='AG', handicap_index=Decimal('12.0'))
        fs = Foursome.objects.create(round=self.round, group_number=1)
        FoursomeMembership.objects.create(foursome=fs, player=p, tee=self.m_white,
                                          course_handicap=12, playing_handicap=12)
        HoleScore.objects.create(foursome=fs, player=p, hole_number=1,
                                 gross_score=4)

    def test_it_locks_once_somebody_has_teed_off(self):
        """The basis decides how every hole is netted; moving it after play
        starts rewrites results nobody asked to change."""
        self._tee_off()
        self.assertTrue(self.client.get(self.url).data['locked'])
        r = self.client.post(self.url, {'tee_id': self.m_white.id}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('teed off', r.data['detail'])
        self.assertEqual(self.client.delete(self.url, format='json').status_code,
                         400)

    def test_it_is_open_before_anybody_tees_off(self):
        self.assertFalse(self.client.get(self.url).data['locked'])

    # ------------------------------------------------------------ scoping

    def test_another_account_gets_a_404(self):
        other_acct = Account.objects.create(name='Someone Else')
        intruder = User.objects.create_user(username='nosy', account=other_acct)
        c = APIClient(); c.force_authenticate(intruder)
        self.assertEqual(c.get(self.url).status_code, 404)
        self.assertEqual(
            c.post(self.url, {'tee_id': self.m_white.id},
                   format='json').status_code, 404)
