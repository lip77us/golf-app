"""
api/test_watchers.py
--------------------
Invite watchers — non-playing spectators who follow a round/tournament in-app
(read-only). Any participant (not just the TD) can invite; the watcher is added
to the inviter's My Golfers roster; the round/tournament then surfaces in the
watcher's "Shared with me" (phone-matched) and its leaderboard opens read-only,
but the watcher cannot score.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Round, Foursome, FoursomeMembership, Tournament, Watcher


User = get_user_model()


def _member(foursome, player):
    return FoursomeMembership.objects.create(
        foursome=foursome, player=player, course_handicap=10, playing_handicap=10,
    )


class WatcherTests(TestCase):
    def setUp(self):
        # Account A — the TD / host.
        self.acct_a = Account.objects.create(name='Host Group')
        self.td = User.objects.create_user(username='td', account=self.acct_a)
        self.td.is_account_admin = True
        self.td.save(update_fields=['is_account_admin'])
        # The TD as a Player (so Watcher.invited_by is populated on invite).
        self.td_player = Player.objects.create(
            account=self.acct_a, name='Ryan', phone='(212) 555-0000',
            handicap_index=Decimal('5.0'), user=self.td)
        self.course = Course.objects.create(account=self.acct_a, name='Pebble')

        # A casual multi-group round.
        self.round = Round.objects.create(
            account=self.acct_a, course=self.course, status='in_progress',
            active_games=['skins'],
        )
        self.fs1 = Foursome.objects.create(round=self.round, group_number=1)
        Foursome.objects.create(round=self.round, group_number=2)
        _member(self.fs1, Player.objects.create(
            account=self.acct_a, name='Al', handicap_index=Decimal('9.0')))

        # A tournament with one round.
        self.tournament = Tournament.objects.create(
            account=self.acct_a, name='Member-Guest', start_date=date(2026, 6, 6))
        self.t_round = Round.objects.create(
            account=self.acct_a, course=self.course, status='in_progress',
            tournament=self.tournament, active_games=['skins'],
        )
        Foursome.objects.create(round=self.t_round, group_number=1)

        self.td_client = APIClient(); self.td_client.force_authenticate(self.td)

        # Account B — the watcher's own account; verified phone.
        self.acct_b = Account.objects.create(name='Wanda Watcher')
        self.watcher_user = User.objects.create_user(
            username='wanda', account=self.acct_b)
        self.watcher_user.phone = '+14155557777'
        self.watcher_user.save(update_fields=['phone'])
        self.b_client = APIClient()
        self.b_client.force_authenticate(self.watcher_user)

    # ---- inviting ----
    def test_participant_invites_round_watcher_by_phone(self):
        resp = self.td_client.post(
            reverse('api-round-watchers', args=[self.round.id]),
            {'phone': '(415) 555-7777', 'name': 'Wanda'}, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        # Watcher recorded (normalized) + added to the host's roster.
        self.assertTrue(Watcher.objects.filter(
            round=self.round, phone='+14155557777').exists())
        self.assertTrue(Player.objects.filter(
            account=self.acct_a, phone='(415) 555-7777').exists())

        # Wanda sees it in Shared-with-me and can read the leaderboard…
        shared = self.b_client.get(reverse('api-shared-rounds')).data
        ids = {(r['id'], r['is_tournament']) for r in shared}
        self.assertIn((self.round.id, False), ids)
        self.assertEqual(
            self.b_client.get(reverse('api-leaderboard', args=[self.round.id]))
            .status_code, 200)
        # …but cannot score (not a player in any group).
        self.assertEqual(
            self.b_client.get(reverse('api-scorecard', args=[self.fs1.id]))
            .status_code, 404)

    def test_is_on_app_flag(self):
        # Wanda already has Halved (verified phone) → is_on_app True, so the
        # client skips the download share and the server pings her in-app.
        on = self.td_client.post(
            reverse('api-round-watchers', args=[self.round.id]),
            {'phone': '(415) 555-7777', 'name': 'Wanda'}, format='json')
        self.assertEqual(on.status_code, 201, on.data)
        self.assertTrue(on.data['is_on_app'])
        # A number with no Halved account → is_on_app False (download share).
        off = self.td_client.post(
            reverse('api-round-watchers', args=[self.round.id]),
            {'phone': '(415) 555-1111', 'name': 'Newbie'}, format='json')
        self.assertEqual(off.status_code, 201, off.data)
        self.assertFalse(off.data['is_on_app'])

    def test_tournament_watcher_sees_event(self):
        resp = self.td_client.post(
            reverse('api-tournament-watchers', args=[self.tournament.id]),
            {'phone': '+1 415 555 7777', 'name': 'Wanda'}, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        shared = self.b_client.get(reverse('api-shared-rounds')).data
        row = next((r for r in shared if r['is_tournament']), None)
        self.assertIsNotNone(row)
        self.assertEqual(row['id'], self.tournament.id)
        self.assertEqual(row['group_label'], 'Member-Guest')
        self.assertEqual(
            self.b_client.get(
                reverse('api-tournament-leaderboard', args=[self.tournament.id]))
            .status_code, 200)

    def test_invite_idempotent(self):
        url = reverse('api-round-watchers', args=[self.round.id])
        a = self.td_client.post(url, {'phone': '4155557777', 'name': 'Bob'},
                                format='json')
        b = self.td_client.post(url, {'phone': '(415) 555-7777', 'name': 'Bob'},
                                format='json')
        self.assertEqual(a.status_code, 201)
        self.assertEqual(b.status_code, 200)
        self.assertEqual(
            Watcher.objects.filter(round=self.round).count(), 1)

    def test_invite_requires_name(self):
        resp = self.td_client.post(
            reverse('api-round-watchers', args=[self.round.id]),
            {'phone': '4155557777'}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_invite_requires_phone(self):
        # A roster golfer with no phone can't be made a (matchable) watcher.
        p = Player.objects.create(
            account=self.acct_a, name='No Phone', handicap_index=Decimal('5'))
        resp = self.td_client.post(
            reverse('api-round-watchers', args=[self.round.id]),
            {'player_id': p.id}, format='json')
        self.assertEqual(resp.status_code, 400)

    # ---- mutual connection + watcher-invites-watcher ----
    def test_watcher_join_adds_inviter_to_roster(self):
        self.td_client.post(
            reverse('api-round-watchers', args=[self.round.id]),
            {'phone': '(415) 555-7777', 'name': 'Bob'}, format='json')
        # Bob opens the round → the inviter (Ryan) lands in Bob's My Golfers.
        resp = self.b_client.post(reverse('api-round-join', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertTrue(
            Player.objects.filter(account=self.acct_b, name='Ryan').exists())

    def test_watcher_can_invite_another_watcher(self):
        # Ryan invites Bob; Bob (a watcher) then invites Bill by phone.
        self.td_client.post(
            reverse('api-round-watchers', args=[self.round.id]),
            {'phone': '(415) 555-7777', 'name': 'Bob'}, format='json')
        resp = self.b_client.post(
            reverse('api-round-watchers', args=[self.round.id]),
            {'phone': '(305) 555-1212', 'name': 'Bill'}, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertTrue(Watcher.objects.filter(
            round=self.round, phone='+13055551212').exists())
        # Bill is in Bob's roster (the inviter's account).
        self.assertTrue(
            Player.objects.filter(account=self.acct_b, name='Bill').exists())

    def test_candidates_exclude_current_players(self):
        resp = self.td_client.get(
            reverse('api-round-watcher-candidates', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200)
        names = {p['name'] for p in resp.data}
        self.assertNotIn('Al', names)   # Al is playing in fs1 → not a candidate
        self.assertIn('Ryan', names)    # Ryan isn't a player in this round

    def test_non_participant_cannot_invite(self):
        acct_c = Account.objects.create(name='Outsider')
        carl = User.objects.create_user(username='carl', account=acct_c)
        carl.phone = '+19995550000'; carl.save(update_fields=['phone'])
        c = APIClient(); c.force_authenticate(carl)
        self.assertEqual(
            c.post(reverse('api-round-watchers', args=[self.round.id]),
                   {'phone': '4155551234'}, format='json').status_code, 404)
