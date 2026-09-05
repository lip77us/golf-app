"""
api/test_favorites.py
---------------------
The favorites shortlist behind the player picker's Favorites filter: setting
and unsetting the flag, the `is_favorite` field on the roster, and the two
things that make it a private shortlist — it is per USER, not per account, and
it never crosses the tenant boundary.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import FavoriteGolfer, Player

User = get_user_model()


class FavoriteGolferTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Saturday Group')
        self.user = User.objects.create_user(username='paul', account=self.acct)
        self.other = User.objects.create_user(username='dave', account=self.acct)
        self.dave, self.al, self.guest = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('10.0'))
            for n in ('Dave Moran', 'Al Bronson', 'Ray Okafor')
        ]
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _url(self, player):
        return reverse('api-player-favorite', args=[player.id])

    def _roster(self):
        res = self.client.get(reverse('api-players'))
        self.assertEqual(res.status_code, 200)
        return {row['name']: row for row in res.data}

    # ── setting and unsetting ────────────────────────────────────────────────

    def test_post_sets_and_delete_clears(self):
        res = self.client.post(self._url(self.dave))
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.data['is_favorite'])
        self.assertTrue(
            FavoriteGolfer.objects.filter(
                owner=self.user, player=self.dave).exists())

        res = self.client.delete(self._url(self.dave))
        self.assertEqual(res.status_code, 200)
        self.assertFalse(res.data['is_favorite'])
        self.assertFalse(
            FavoriteGolfer.objects.filter(
                owner=self.user, player=self.dave).exists())

    def test_both_verbs_are_idempotent(self):
        """The picker writes optimistically and an Undo can land after a
        retry, so a second set (or unset) must be a no-op, not a 409."""
        self.client.post(self._url(self.dave))
        res = self.client.post(self._url(self.dave))
        self.assertEqual(res.status_code, 200)
        self.assertEqual(
            FavoriteGolfer.objects.filter(owner=self.user).count(), 1)

        self.client.delete(self._url(self.dave))
        res = self.client.delete(self._url(self.dave))
        self.assertEqual(res.status_code, 200)

    def test_a_guest_can_be_favorited(self):
        """A regular fourth who never signs up is the case the filter is
        for, so there is no on-Halved gate."""
        res = self.client.post(self._url(self.guest))
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.data['is_favorite'])

    # ── the roster reads them back ───────────────────────────────────────────

    def test_roster_reports_is_favorite_per_row(self):
        self.client.post(self._url(self.dave))
        roster = self._roster()
        self.assertTrue(roster['Dave Moran']['is_favorite'])
        self.assertFalse(roster['Al Bronson']['is_favorite'])

    def test_roster_favorites_cost_one_query_not_one_per_golfer(self):
        self.client.post(self._url(self.dave))
        with self.assertNumQueries(2):
            # The roster, then ONE batched favorites lookup — not one per row.
            self.client.get(reverse('api-players'))

    # ── private to the owner ─────────────────────────────────────────────────

    def test_favorites_are_per_user_not_per_account(self):
        self.client.post(self._url(self.dave))
        self.client.force_authenticate(self.other)
        roster = self._roster()
        self.assertFalse(roster['Dave Moran']['is_favorite'])

    def test_cannot_favorite_a_golfer_in_another_account(self):
        stranger_acct = Account.objects.create(name='Member Guest')
        stranger = Player.objects.create(
            account=stranger_acct, name='Outsider', handicap_index=Decimal('9'))
        res = self.client.post(self._url(stranger))
        self.assertEqual(res.status_code, 404)
        self.assertFalse(FavoriteGolfer.objects.exists())

    def test_a_non_admin_can_favorite(self):
        """Favoriting is a private shortlist entry, not roster management."""
        self.assertFalse(self.user.is_account_admin)
        res = self.client.post(self._url(self.al))
        self.assertEqual(res.status_code, 200)
