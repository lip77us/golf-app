"""
api/test_tournament_delete.py
-----------------------------
Deleting a tournament must DELETE its rounds, not orphan them.

`Round.tournament` is `on_delete=SET_NULL`, so a bare `tournament.delete()`
would null each round's tournament FK rather than remove the round — and an
orphaned round (tournament=None) then wrongly resurfaces in the casual-rounds
list (`CasualRoundListView` filters `tournament__isnull=True`).
`TournamentDetailView.delete` deletes the rounds first; these tests lock that in.
"""

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Tournament, Round, Foursome, FoursomeMembership

User = get_user_model()


class TournamentDeleteTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Paul Group')
        self.user = User.objects.create_user(username='paul', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.player = Player.objects.create(
            account=self.account, name='Paul', handicap_index='10.0',
            user=self.user,
        )
        self.course = Course.objects.create(account=self.account, name='Pebble')

        self.tournament = Tournament.objects.create(
            account=self.account, name='Club Champ', start_date='2026-07-12',
        )
        # A tournament round carrying a pink ball side game, with Paul playing.
        self.round = Round.objects.create(
            account=self.account, course=self.course,
            tournament=self.tournament, status='in_progress',
            active_games=['pink_ball'],
        )
        fs = Foursome.objects.create(round=self.round, group_number=1)
        FoursomeMembership.objects.create(
            foursome=fs, player=self.player,
            course_handicap=10, playing_handicap=10,
        )

        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_delete_removes_rounds_not_orphans(self):
        rid = self.round.id
        resp = self.client.delete(
            reverse('api-tournament-detail', args=[self.tournament.id]),
        )
        self.assertEqual(resp.status_code, 204)
        # Round is GONE — not left behind with tournament=NULL.
        self.assertFalse(Round.objects.filter(id=rid).exists())
        self.assertFalse(
            Tournament.objects.filter(id=self.tournament.id).exists()
        )

    def test_deleted_tournament_round_not_in_casual_list(self):
        rid = self.round.id
        self.client.delete(
            reverse('api-tournament-detail', args=[self.tournament.id]),
        )
        resp = self.client.get(
            reverse('api-casual-rounds'), {'status': 'in_progress'},
        )
        self.assertEqual(resp.status_code, 200)
        ids = [r['id'] for r in resp.json()]
        self.assertNotIn(rid, ids)
