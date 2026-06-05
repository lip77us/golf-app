"""
api/test_delegated_scoring.py
-----------------------------
Delegated cross-account scoring: a TD designates an on-app golfer in a foursome
as its scorer; that (phone-matched) user — in their OWN account — can open the
round, read the scorecard, and see the leaderboard, while non-designated users
remain blocked. Own-account access is preserved.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Round, Foursome, FoursomeMembership


User = get_user_model()


def _member(foursome, player):
    return FoursomeMembership.objects.create(
        foursome=foursome, player=player, course_handicap=10, playing_handicap=10,
    )


class DelegatedScoringTests(TestCase):
    def setUp(self):
        # Account A — the Tournament Director's account.
        self.acct_a = Account.objects.create(name='TD Group')
        self.td = User.objects.create_user(username='td', account=self.acct_a)
        self.td.is_account_admin = True
        self.td.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct_a, name='Pebble')
        self.round = Round.objects.create(
            account=self.acct_a, course=course, status='in_progress',
            active_games=['skins'],
        )
        # Two groups (multi-foursome). Group 1 has the scorer.
        self.fs1 = Foursome.objects.create(round=self.round, group_number=1)
        self.fs2 = Foursome.objects.create(round=self.round, group_number=2)
        self.scorer_player = Player.objects.create(
            account=self.acct_a, name='Bob', phone='(310) 555-0101',
            handicap_index=Decimal('9.0'),
        )
        self.other_player = Player.objects.create(
            account=self.acct_a, name='Cal', phone='415-555-2222',
            handicap_index=Decimal('12.0'),
        )
        _member(self.fs1, self.scorer_player)
        _member(self.fs1, self.other_player)

        self.td_client = APIClient(); self.td_client.force_authenticate(self.td)

        # Account B — the scorer's own account; verified phone matches Bob.
        self.acct_b = Account.objects.create(name='Bob Golf')
        self.scorer = User.objects.create_user(username='bob', account=self.acct_b)
        self.scorer.phone = '+13105550101'
        self.scorer.save(update_fields=['phone'])
        self.b_client = APIClient(); self.b_client.force_authenticate(self.scorer)

    def _designate(self, foursome, player):
        return self.td_client.post(
            reverse('api-foursome-scorer', args=[foursome.id]),
            {'player_id': player.id}, format='json',
        )

    # ---- designation ----
    def test_td_designates_scorer(self):
        resp = self._designate(self.fs1, self.scorer_player)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertIn(self.scorer_player.id, resp.data['scorer_player_ids'])
        self.assertTrue(
            FoursomeMembership.objects.get(
                foursome=self.fs1, player=self.scorer_player).is_scorer
        )

    def test_designate_rejects_non_member(self):
        resp = self.td_client.post(
            reverse('api-foursome-scorer', args=[self.fs2.id]),
            {'player_id': self.scorer_player.id}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    # ---- scorer access (after designation) ----
    def test_scorer_can_reach_round_and_scorecard(self):
        self._designate(self.fs1, self.scorer_player)

        # scoring-for-me lists the round + my foursome.
        sfm = self.b_client.get(reverse('api-scoring-for-me'))
        self.assertEqual(sfm.status_code, 200)
        self.assertEqual(len(sfm.data), 1)
        self.assertEqual(sfm.data[0]['id'], self.round.id)
        self.assertEqual(sfm.data[0]['your_foursome_id'], self.fs1.id)

        # Open the round (round_for_scorer) + scorecard (foursome_for_scorer).
        self.assertEqual(
            self.b_client.get(reverse('api-round-detail', args=[self.round.id]))
            .status_code, 200)
        self.assertEqual(
            self.b_client.get(reverse('api-scorecard', args=[self.fs1.id]))
            .status_code, 200)
        # Whole-field leaderboard (round_for_reader).
        self.assertEqual(
            self.b_client.get(reverse('api-leaderboard', args=[self.round.id]))
            .status_code, 200)

    # ---- non-scorer blocked ----
    def test_non_scorer_blocked(self):
        # No designation yet → B is not a scorer.
        self.assertEqual(self.b_client.get(reverse('api-scoring-for-me')).data, [])
        self.assertEqual(
            self.b_client.get(reverse('api-scorecard', args=[self.fs1.id]))
            .status_code, 404)
        self.assertEqual(
            self.b_client.get(reverse('api-round-detail', args=[self.round.id]))
            .status_code, 404)

    def test_unrelated_user_blocked_even_after_designation(self):
        self._designate(self.fs1, self.scorer_player)
        acct_c = Account.objects.create(name='Carl')
        carl = User.objects.create_user(username='carl', account=acct_c)
        carl.phone = '+19995550000'; carl.save(update_fields=['phone'])
        c = APIClient(); c.force_authenticate(carl)
        self.assertEqual(c.get(reverse('api-scoring-for-me')).data, [])
        self.assertEqual(
            c.get(reverse('api-scorecard', args=[self.fs1.id])).status_code, 404)

    # ---- own-account preserved ----
    def test_td_own_account_access_preserved(self):
        self.assertEqual(
            self.td_client.get(reverse('api-scorecard', args=[self.fs1.id]))
            .status_code, 200)
        self.assertEqual(
            self.td_client.get(reverse('api-round-detail', args=[self.round.id]))
            .status_code, 200)

    # ---- Shared-with-me leaderboard read still works (non-scorer participant) ----
    def test_phone_matched_participant_can_read_leaderboard_not_score(self):
        # Bob is a participant (matches phone) but NOT designated scorer.
        self.assertEqual(
            self.b_client.get(reverse('api-leaderboard', args=[self.round.id]))
            .status_code, 200)  # round_for_reader allows participant
        self.assertEqual(
            self.b_client.get(reverse('api-scorecard', args=[self.fs1.id]))
            .status_code, 404)  # but cannot score (not is_scorer)
