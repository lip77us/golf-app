"""
api/test_live_activity_token.py
-------------------------------
The Live Activity token endpoint
(docs/design-review/handoff-sixes-lock/SPEC.md).

The row is a mailbox for one golfer's activity on one round.  iOS may reissue
the token mid-round, so the interesting behaviour is that a second POST
*replaces* rather than appends — a duplicate would mean pushing the same board
twice, once to an address that no longer resolves.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import (Foursome, FoursomeMembership, LiveActivityToken,
                               Round)

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class LiveActivityTokenTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Sixes Club')
        course = Course.objects.create(account=self.acct, name='Pebble')
        tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['sixes'], bet_unit=Decimal('1.00'))
        fs = Foursome.objects.create(round=self.round, group_number=1)

        self.user = User.objects.create_user(username='dune',
                                             account=self.acct)
        player = Player.objects.create(account=self.acct, name='Dune',
                                       handicap_index=Decimal('10'),
                                       user=self.user)
        FoursomeMembership.objects.create(
            foursome=fs, player=player, tee=tee,
            course_handicap=10, playing_handicap=10)

        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-round-live-activity-token',
                           args=[self.round.id])

    def _post(self, token):
        return self.client.post(self.url, {'token': token}, format='json')

    # -- registering ------------------------------------------------------

    def test_post_stores_the_token(self):
        resp = self._post('abc123')
        self.assertEqual(resp.status_code, 200, resp.data)
        row = LiveActivityToken.objects.get(round=self.round, user=self.user)
        self.assertEqual(row.token, 'abc123')

    def test_reissued_token_replaces_rather_than_appends(self):
        """iOS can hand out a new token mid-round.  Pushing to the old one
        after that is a request into the void, so the row must move."""
        self._post('first')
        self._post('second')
        rows = LiveActivityToken.objects.filter(round=self.round,
                                                user=self.user)
        self.assertEqual(rows.count(), 1)
        self.assertEqual(rows.first().token, 'second')

    def test_empty_token_is_rejected(self):
        resp = self._post('   ')
        self.assertEqual(resp.status_code, 400)
        self.assertFalse(LiveActivityToken.objects.exists())

    # -- ending -----------------------------------------------------------

    def test_delete_clears_it(self):
        self._post('abc123')
        resp = self.client.delete(self.url)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertFalse(LiveActivityToken.objects.exists())

    def test_delete_with_nothing_registered_is_fine(self):
        """The app calls this on every round sign, whether or not an activity
        ever started."""
        self.assertEqual(self.client.delete(self.url).status_code, 200)

    # -- access -----------------------------------------------------------

    def test_a_stranger_cannot_register_against_the_round(self):
        """Same-account users are readers by design — that is how the
        leaderboard works.  The stranger is someone from another club."""
        elsewhere = Account.objects.create(name='Another Club')
        other = User.objects.create_user(username='nobody', account=elsewhere)
        self.client.force_authenticate(other)
        self.assertNotEqual(self._post('abc123').status_code, 200)
        self.assertFalse(LiveActivityToken.objects.exists())

    def test_two_golfers_hold_separate_rows(self):
        """All four run their own activity — the money line differs."""
        self._post('dune-token')
        mate = User.objects.create_user(username='slate', account=self.acct)
        player = Player.objects.create(account=self.acct, name='Slate',
                                       handicap_index=Decimal('8'),
                                       user=mate)
        FoursomeMembership.objects.create(
            foursome=self.round.foursomes.first(), player=player,
            tee=Tee.objects.first(), course_handicap=8, playing_handicap=8)
        self.client.force_authenticate(mate)
        self._post('slate-token')
        self.assertEqual(
            LiveActivityToken.objects.filter(round=self.round).count(), 2)
