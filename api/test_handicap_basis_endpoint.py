"""
api/test_handicap_basis_endpoint.py
-----------------------------------
`GET/POST/DELETE /api/tournaments/{id}/handicap-basis/`.

The field existed before this endpoint did, which made it the
shipped-and-unreachable shape this repo keeps hitting — so what is pinned
here is mostly reachability and the refusals.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Tee
from tournament.models import Round, Tournament

User = get_user_model()


def _holes():
    return [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
            for n in range(1, 19)]


class HandicapBasisEndpointTests(TestCase):

    def setUp(self):
        self.account = Account.objects.create(name='Basis Acct')
        self.user = User.objects.create_user(username='td', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        self.course = Course.objects.create(account=self.account, name='Tilden Park')
        self.mens_white = Tee.objects.create(
            course=self.course, tee_name='White', sex='M', par=70,
            course_rating=Decimal('69.0'), slope=122, holes=_holes())
        self.womens_white = Tee.objects.create(
            course=self.course, tee_name='WHITE', sex='W', par=71,
            course_rating=Decimal('73.5'), slope=129, holes=_holes())

        self.tour = Tournament.objects.create(
            account=self.account, name='TPSGC Cup', start_date=date(2026, 10, 8))
        self.round = Round.objects.create(
            account=self.account, tournament=self.tour, course=self.course,
            round_number=1, date=date(2026, 10, 8))
        self.url = reverse('api-tournament-handicap-basis', args=[self.tour.id])

    def test_it_starts_unset_and_offers_the_tees_in_play(self):
        r = self.client.get(self.url)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIsNone(r.data['basis'])
        names = {(c['tee_name'], c['sex']) for c in r.data['candidates']}
        self.assertEqual(names, {('White', 'M'), ('WHITE', 'W')})

    def test_setting_the_tournament_default(self):
        r = self.client.post(self.url, {'tee_id': self.mens_white.id}, format='json')
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data['basis']['tee_id'], self.mens_white.id)
        self.assertEqual(r.data['basis']['course_rating'], 69.0)
        self.tour.refresh_from_db()
        self.assertEqual(self.tour.handicap_basis_tee_id, self.mens_white.id)

    def test_a_round_can_override_the_tournament(self):
        """A cup plays several rounds, possibly on different courses."""
        self.client.post(self.url, {'tee_id': self.mens_white.id}, format='json')
        r = self.client.post(self.url, {'tee_id': self.womens_white.id,
                                        'round_id': self.round.id}, format='json')
        self.assertEqual(r.data['basis']['tee_id'], self.mens_white.id)
        self.assertEqual(r.data['rounds'][0]['basis']['tee_id'],
                         self.womens_white.id)

    def test_clearing_the_round_leaves_the_tournament(self):
        self.client.post(self.url, {'tee_id': self.mens_white.id}, format='json')
        self.client.post(self.url, {'tee_id': self.womens_white.id,
                                    'round_id': self.round.id}, format='json')
        r = self.client.delete(self.url, {'round_id': self.round.id}, format='json')
        self.assertIsNone(r.data['rounds'][0]['basis'])
        self.assertEqual(r.data['basis']['tee_id'], self.mens_white.id)

    def test_clearing_the_tournament_goes_back_to_the_group_rule(self):
        self.client.post(self.url, {'tee_id': self.mens_white.id}, format='json')
        r = self.client.delete(self.url, format='json')
        self.assertIsNone(r.data['basis'])

    def test_a_tee_from_another_course_is_refused(self):
        """Its rating describes ground nobody is walking."""
        other = Course.objects.create(account=self.account, name='Metropolitan')
        foreign = Tee.objects.create(
            course=other, tee_name='Blue', sex='M', par=71,
            course_rating=Decimal('70.1'), slope=120, holes=_holes())
        r = self.client.post(self.url, {'tee_id': foreign.id}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('nobody is walking', r.data['detail'])

    def test_a_retired_tee_revision_is_not_offered(self):
        """Superseded tees are history; a basis has to be a current rating."""
        self.womens_white.superseded_by = self.mens_white
        self.womens_white.save(update_fields=['superseded_by'])
        r = self.client.get(self.url)
        self.assertEqual([c['tee_id'] for c in r.data['candidates']],
                         [self.mens_white.id])

    def test_it_says_that_a_drawn_event_does_not_move_on_its_own(self):
        """Handicaps are snapshotted at setup. A TD who sets this and sees
        nothing change would reasonably think it had not saved."""
        r = self.client.get(self.url)
        self.assertIn('already drawn', r.data['applies_to'])

    def test_another_account_cannot_read_or_set_it(self):
        other_acct = Account.objects.create(name='Someone Else')
        intruder = User.objects.create_user(username='nosy', account=other_acct)
        c = APIClient(); c.force_authenticate(intruder)
        self.assertEqual(c.get(self.url).status_code, 404)
        self.assertEqual(
            c.post(self.url, {'tee_id': self.mens_white.id},
                   format='json').status_code, 404)

    def test_tee_id_is_required(self):
        r = self.client.post(self.url, {}, format='json')
        self.assertEqual(r.status_code, 400)


class ItRemembersOnTheCourse(TestCase):
    """Paul, 17 Oct: default to the last one used — kept on the COURSE, so
    the next event here comes out right with nobody setting it, and casual
    rounds get the same basis."""

    def setUp(self):
        self.account = Account.objects.create(name='Remember Acct')
        self.user = User.objects.create_user(username='td2', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.course = Course.objects.create(account=self.account, name='Tilden Park')
        self.mens_white = Tee.objects.create(
            course=self.course, tee_name='White', sex='M', par=70,
            course_rating=Decimal('69.0'), slope=122, holes=_holes())
        self.blue = Tee.objects.create(
            course=self.course, tee_name='Blue', sex='M', par=70,
            course_rating=Decimal('71.2'), slope=125, holes=_holes())
        self.tour = Tournament.objects.create(
            account=self.account, name='Cup', start_date=date(2026, 10, 8))
        Round.objects.create(account=self.account, tournament=self.tour,
                             course=self.course, round_number=1,
                             date=date(2026, 10, 8))
        self.url = reverse('api-tournament-handicap-basis', args=[self.tour.id])

    def test_setting_it_fills_the_blank_course_default(self):
        self.client.post(self.url, {'tee_id': self.mens_white.id}, format='json')
        self.course.refresh_from_db()
        self.assertEqual(self.course.default_basis_tee_id, self.mens_white.id)

    def test_a_course_that_already_has_one_is_not_overwritten(self):
        """A single event is not grounds to change the course's answer."""
        self.course.default_basis_tee = self.mens_white
        self.course.save(update_fields=['default_basis_tee'])
        self.client.post(self.url, {'tee_id': self.blue.id}, format='json')
        self.course.refresh_from_db()
        self.assertEqual(self.course.default_basis_tee_id, self.mens_white.id)
        self.tour.refresh_from_db()
        self.assertEqual(self.tour.handicap_basis_tee_id, self.blue.id,
                         'the tournament still takes the new one')

    def test_remember_on_course_can_be_declined(self):
        self.client.post(self.url, {'tee_id': self.mens_white.id,
                                    'remember_on_course': False}, format='json')
        self.course.refresh_from_db()
        self.assertIsNone(self.course.default_basis_tee_id)

    def test_the_response_shows_where_it_would_come_from(self):
        self.client.post(self.url, {'tee_id': self.mens_white.id}, format='json')
        r = self.client.get(self.url)
        cd = r.data['course_defaults']
        self.assertEqual(len(cd), 1)
        self.assertEqual(cd[0]['course_name'], 'Tilden Park')
        self.assertEqual(cd[0]['basis']['tee_id'], self.mens_white.id)

    def test_a_casual_round_at_that_course_now_uses_it(self):
        """No tournament, same number — which is the point of the course tier."""
        from scoring.handicap import basis_rating_for
        self.client.post(self.url, {'tee_id': self.mens_white.id}, format='json')
        casual = Round.objects.create(account=self.account, course=self.course,
                                      round_number=1, date=date(2026, 10, 17))
        casual.refresh_from_db()
        self.assertEqual(basis_rating_for(casual), 69.0)
