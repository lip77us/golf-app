"""
api/test_spots.py
-----------------
Spots setup / tally / result endpoints round-trip through the
serializer/view/urls. (The settlement math is covered by
scoring/tests/test_spots.py.)
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership

User = get_user_model()

#: Holes 3 and 7 are par 3s, because a greenie only exists on one — an
#: all-par-4 card could never exercise the pick or the carry.
HOLES = [{'number': n, 'par': (3 if n in (3, 7) else 4),
          'stroke_index': n, 'yards': (165 if n in (3, 7) else 400)}
         for n in range(1, 19)]


class SpotsEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Spots Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['nassau', 'spots'], bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('0'))
            for n in ('A', 'B', 'C', 'D')
        ]
        for p in self.players:
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.ids = [p.id for p in self.players]

    def _setup(self, **over):
        body = {'bet_unit': '1.00', 'payout_style': 'pay_around'}
        body.update(over)
        return self.client.post(
            reverse('api-spots-setup', args=[self.fs.id]), body, format='json')

    def test_setup_returns_summary(self):
        resp = self._setup()
        self.assertEqual(resp.status_code, 201, resp.data)
        # Legacy 'pay_around' normalizes to the 2-axis per_point/'all'.
        self.assertEqual(resp.data['payout_style'], 'per_point')
        self.assertEqual(resp.data['per_point_mode'], 'all')
        self.assertEqual(resp.data['money']['total_spots'], 0)

    def test_tally_then_summary_reflects_counts(self):
        self._setup()
        resp = self.client.post(
            reverse('api-spots-tally', args=[self.fs.id]),
            {'hole_number': 3,
             'entries': [{'player_id': self.ids[0],
                          'types': ['sandy', 'chippy']}]},
            format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['money']['total_spots'], 2)
        winner = next(p for p in resp.data['players'] if p['spots'] == 2)
        self.assertEqual(winner['player_id'], self.ids[0])
        self.assertEqual(winner['payout'], 6.0)  # pay-around, foursome

        # GET mirrors it.
        got = self.client.get(reverse('api-spots-result', args=[self.fs.id]))
        self.assertEqual(got.data['money']['total_spots'], 2)

    def test_tally_without_setup_auto_creates_and_credits(self):
        # Spots added but never configured: the first tally auto-creates the game
        # with defaults and credits the spot (was a 400 before — which silently
        # dropped a spot recorded on an unconfigured side game).
        resp = self.client.post(
            reverse('api-spots-tally', args=[self.fs.id]),
            {'hole_number': 1,
             'entries': [{'player_id': self.ids[0], 'types': ['sandy']}]},
            format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['status'], 'in_progress')
        self.assertEqual(resp.data['money']['total_spots'], 1)
        winner = next(p for p in resp.data['players'] if p['spots'] == 1)
        self.assertEqual(winner['player_id'], self.ids[0])


class TypesInPlayEndpointTests(SpotsEndpointTests):
    """Which spots are being played travels with every read, because the
    leaderboard's In play card and the hole sheet are both built from it."""

    def test_setup_defaults_are_returned_when_types_are_OMITTED(self):
        resp = self._setup()
        slugs = [t['type'] for t in resp.data['in_play']]
        self.assertEqual(slugs, ['greenie', 'sandy', 'birdie', 'eagle',
                                 'chippy'])
        self.assertTrue(resp.data['greenie']['carry'])
        self.assertEqual(resp.data['birdie_basis'], 'gross')

    def test_an_EMPTY_list_is_refused_with_a_reason(self):
        """Omitted means defaults; empty means nothing in play, which can
        only pay nobody. The two must not collapse into each other."""
        resp = self._setup(types=[])
        self.assertEqual(resp.status_code, 400, resp.data)
        self.assertIn('at least one', resp.data['detail'].lower())

    def test_an_unknown_slug_is_refused_by_the_serializer(self):
        self.assertEqual(self._setup(types=['sandy', 'nonsense']).status_code,
                         400)

    def test_the_sheet_types_exclude_the_greenie_and_the_derived_ones(self):
        resp = self._setup(types=['greenie', 'sandy', 'birdie', 'eagle',
                                  'snake'])
        self.assertEqual([t['type'] for t in resp.data['sheet_types']],
                         ['sandy', 'snake'])

    def test_every_type_carries_its_LABEL_not_just_a_slug(self):
        resp = self._setup(types=['eagle'])
        self.assertEqual(resp.data['in_play'],
                         [{'type': 'eagle', 'label': 'Eagle or better',
                           'worth': 2}])

    def test_a_hole_names_the_types_it_was_given(self):
        self._setup(types=['sandy', 'chippy'])
        resp = self.client.post(
            reverse('api-spots-tally', args=[self.fs.id]),
            {'hole_number': 5,
             'entries': [{'player_id': self.ids[0],
                          'types': ['chippy', 'sandy']}]},
            format='json')
        hole = resp.data['holes'][0]
        self.assertEqual(hole['hole'], 5)
        self.assertEqual([t['label'] for t in hole['spots'][0]['types']],
                         ['Sandy', 'Chippy'])

    def test_an_empty_types_list_CLEARS_the_hole(self):
        """The commonest correction there is, so the serializer allows it."""
        self._setup()
        url = reverse('api-spots-tally', args=[self.fs.id])
        self.client.post(url, {'hole_number': 5, 'entries': [
            {'player_id': self.ids[0], 'types': ['sandy']}]}, format='json')
        resp = self.client.post(url, {'hole_number': 5, 'entries': [
            {'player_id': self.ids[0], 'types': []}]}, format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['money']['total_spots'], 0)


class GreenieEndpointTests(SpotsEndpointTests):
    """The pick, Nobody, and the difference between Nobody and undecided."""

    def _pick(self, hole, player_id):
        return self.client.post(
            reverse('api-spots-greenie', args=[self.fs.id]),
            {'hole_number': hole, 'player_id': player_id}, format='json')

    def test_a_winner_takes_one_spot(self):
        self._setup()
        resp = self._pick(3, self.ids[0])
        self.assertEqual(resp.status_code, 200, resp.data)
        winner = next(p for p in resp.data['players']
                      if p['player_id'] == self.ids[0])
        self.assertEqual(winner['spots'], 1)

    def test_NOBODY_rolls_it_and_the_next_par_3_says_so(self):
        self._setup()
        resp = self._pick(3, None)
        nxt = resp.data['greenie']['next']
        self.assertEqual((nxt['hole'], nxt['worth']), (7, 2))
        self.assertEqual(nxt['carried_from'], 3)
        self.assertEqual(resp.data['money']['total_spots'], 0)

    def test_DELETE_puts_it_back_to_undecided(self):
        self._setup()
        self._pick(3, None)
        resp = self.client.delete(
            reverse('api-spots-greenie', args=[self.fs.id]),
            {'hole_number': 3}, format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        nxt = resp.data['greenie']['next']
        self.assertEqual((nxt['hole'], nxt['worth']), (3, 1))

    def test_a_golfer_from_another_group_is_refused(self):
        self._setup()
        other = Player.objects.create(account=self.acct, name='Z',
                                      handicap_index=Decimal('0'))
        resp = self._pick(3, other.id)
        self.assertEqual(resp.status_code, 400, resp.data)

    def test_the_pick_works_without_setup(self):
        """Spots can be switched on in the picker and never configured; the
        first tap on a par 3 has to work."""
        resp = self._pick(3, self.ids[0])
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['status'], 'in_progress')

    def test_a_bad_hole_number_on_DELETE_is_a_400(self):
        self._setup()
        resp = self.client.delete(
            reverse('api-spots-greenie', args=[self.fs.id]),
            {'hole_number': 99}, format='json')
        self.assertEqual(resp.status_code, 400)


class BirdieBasisEndpointTests(SpotsEndpointTests):
    def test_the_basis_round_trips(self):
        resp = self._setup(types=['birdie'], birdie_basis='net_so',
                           net_percent=90)
        self.assertEqual(resp.data['birdie_basis'], 'net_so')
        self.assertEqual(resp.data['net_percent'], 90)

    def test_a_birdie_needs_no_tally_at_all(self):
        """It is read off the scorecard, so it appears without anyone
        touching the Spots sheet."""
        from scoring.models import HoleScore
        self._setup(types=['birdie'])
        HoleScore.objects.create(foursome=self.fs, player_id=self.ids[0],
                                 hole_number=1, gross_score=3)   # par 4
        got = self.client.get(reverse('api-spots-result', args=[self.fs.id]))
        winner = next(p for p in got.data['players']
                      if p['player_id'] == self.ids[0])
        self.assertEqual(winner['spots'], 1)
