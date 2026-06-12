"""
api/test_withdrawal.py
----------------------
Mid-round withdrawal ("can't continue"): the withdraw-player endpoint marks a
player out after a given hole (keeping their earlier scores), the round can
then complete even though that player has no later-hole scores, and an
abandoned ("killed") hole is exempt from the completion check.

See docs/mid-round-withdrawal.md.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from scoring.models import HoleScore
from tournament.models import Round, Foursome, FoursomeMembership


User = get_user_model()


class WithdrawalTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='TD Group')
        self.td = User.objects.create_user(username='td', account=self.acct)
        self.td.is_account_admin = True
        self.td.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['skins'], bet_unit=Decimal('10'),
        )
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = []
        for i, name in enumerate(['Al', 'Bo', 'Cy', 'Di']):
            p = Player.objects.create(
                account=self.acct, name=name, handicap_index=Decimal('10.0'),
            )
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, course_handicap=10, playing_handicap=10,
            )
            self.players.append(p)

        from services.skins import setup_skins
        setup_skins(self.fs, handicap_mode='gross', carryover=False)

        self.client = APIClient()
        self.client.force_authenticate(self.td)

    def _score(self, players, hole, gross):
        for p in players:
            HoleScore.objects.update_or_create(
                foursome=self.fs, player=p, hole_number=hole,
                defaults={'gross_score': gross},
            )

    def _withdraw(self, player, after_hole, **body):
        return self.client.post(
            reverse('api-foursome-withdraw-player', args=[self.fs.id]),
            {'player_id': player.id, 'after_hole': after_hole, **body},
            format='json',
        )

    def test_withdraw_sets_field_and_killed_hole(self):
        resp = self._withdraw(self.players[3], 9, kill_next_hole=True)
        assert resp.status_code == 200, resp.content
        assert resp.data['withdrew_after_hole'] == 9
        assert resp.data['killed_hole'] == 10
        m = self.fs.memberships.get(player=self.players[3])
        assert m.withdrew_after_hole == 9
        assert m.withdrew_killed_next_hole is True

    def test_round_completes_with_withdrawn_player_and_killed_hole(self):
        all4 = self.players
        survivors = self.players[:3]   # Di withdraws
        # Holes 1-9 scored by all four.
        for h in range(1, 10):
            self._score(all4, h, 4)
        # Withdraw Di after hole 9; hole 10 abandoned.
        self._withdraw(self.players[3], 9, kill_next_hole=True)
        # Survivors finish 11-18 (hole 10 is killed → never scored).
        for h in range(11, 19):
            self._score(survivors, h, 4)

        resp = self.client.post(reverse('api-round-complete', args=[self.round.id]))
        assert resp.status_code == 200, resp.content
        assert resp.data['status'] == 'complete', resp.data
        assert resp.data['all_foursomes_done'] is True

    def test_round_blocked_without_withdrawal(self):
        """Control: with no WD recorded, a fully-unscored hole keeps the
        round open — only a killed hole is exempt from coverage."""
        for h in range(1, 19):
            if h == 10:
                continue   # hole 10 entirely unscored, no withdrawal
            self._score(self.players, h, 4)
        resp = self.client.post(reverse('api-round-complete', args=[self.round.id]))
        assert resp.status_code == 200, resp.content
        assert resp.data['status'] == 'in_progress', resp.data
        assert resp.data['all_foursomes_done'] is False

    def test_reinstate_clears_withdrawal(self):
        self._withdraw(self.players[3], 9, kill_next_hole=True)
        resp = self.client.post(
            reverse('api-foursome-reinstate-player', args=[self.fs.id]),
            {'player_id': self.players[3].id}, format='json',
        )
        assert resp.status_code == 200, resp.content
        m = self.fs.memberships.get(player=self.players[3])
        assert m.withdrew_after_hole is None
        assert m.withdrew_killed_next_hole is False
