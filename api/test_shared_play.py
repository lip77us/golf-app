"""
api/test_shared_play.py
-----------------------
Participant (not just designated scorer) access to shared multi-foursome rounds:

  * `playing-for-me` lists tournaments / multi-group skins a friend added me to
    (and excludes single-group casual rounds — those stay in Shared-with-me).
  * opening a round (`<id>/join/`) mirrors the TD into my "My Golfers" roster and
    copies the course into my account, idempotently.
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


class SharedPlayTests(TestCase):
    def setUp(self):
        # Account A — the TD. The TD is a Player linked to a User with a phone.
        self.acct_a = Account.objects.create(name='TD Group')
        self.td_user = User.objects.create_user(username='td', account=self.acct_a)
        self.td_user.phone = '+14155559999'
        self.td_user.save(update_fields=['phone'])
        self.td_player = Player.objects.create(
            account=self.acct_a, name='Tom Director', short_name='Tom',
            phone='(415) 555-9999', handicap_index=Decimal('6.0'),
            user=self.td_user,
        )
        self.course = Course.objects.create(
            account=self.acct_a, name='Pebble', golf_api_id='gapi-pebble',
        )

        # Multi-group skins round (2 foursomes, no tournament) created by the TD.
        self.round = Round.objects.create(
            account=self.acct_a, course=self.course, status='in_progress',
            active_games=['skins'], created_by=self.td_player,
        )
        self.fs1 = Foursome.objects.create(round=self.round, group_number=1)
        self.fs2 = Foursome.objects.create(round=self.round, group_number=2)
        self.bob_a = Player.objects.create(
            account=self.acct_a, name='Bob', phone='(310) 555-0101',
            handicap_index=Decimal('9.0'),
        )
        _member(self.fs1, self.bob_a)

        # A single-group casual round Bob is also in — should NOT appear.
        self.solo = Round.objects.create(
            account=self.acct_a, course=self.course, status='in_progress',
            active_games=['nassau'], created_by=self.td_player,
        )
        _member(Foursome.objects.create(round=self.solo, group_number=1), self.bob_a)

        # Account B — Bob's own account; verified phone matches Bob's Player.
        self.acct_b = Account.objects.create(name='Bob Golf')
        self.bob = User.objects.create_user(username='bob', account=self.acct_b)
        self.bob.phone = '+13105550101'
        self.bob.save(update_fields=['phone'])
        self.b_client = APIClient(); self.b_client.force_authenticate(self.bob)

    # ---- discovery ----
    def test_playing_for_me_lists_multi_group_round(self):
        resp = self.b_client.get(reverse('api-playing-for-me'))
        self.assertEqual(resp.status_code, 200)
        ids = {r['id'] for r in resp.data}
        self.assertIn(self.round.id, ids)          # multi-group skins → listed
        self.assertNotIn(self.solo.id, ids)        # single group → excluded
        row = next(r for r in resp.data if r['id'] == self.round.id)
        self.assertEqual(row['your_foursome_id'], self.fs1.id)
        self.assertFalse(row['is_tournament'])  # casual multi-group skins

    def test_playing_for_me_empty_without_phone(self):
        u = User.objects.create_user(username='nophone', account=self.acct_b)
        c = APIClient(); c.force_authenticate(u)
        self.assertEqual(c.get(reverse('api-playing-for-me')).data, [])

    # ---- join (mirror TD + course) ----
    def test_join_adds_td_friend_and_course_idempotently(self):
        # Pre: Bob's account has neither the TD nor the course.
        self.assertFalse(Player.objects.filter(account=self.acct_b).exists())
        self.assertFalse(Course.objects.filter(account=self.acct_b).exists())

        resp = self.b_client.post(reverse('api-round-join', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertTrue(resp.data['td_added'])
        self.assertTrue(resp.data['course_added'])

        # TD now in Bob's roster, phone-matched.
        td = Player.objects.get(account=self.acct_b, name='Tom Director')
        from accounts.phone import normalize
        self.assertEqual(normalize(td.phone), '+14155559999')
        # Course copied in.
        self.assertTrue(
            Course.objects.filter(account=self.acct_b,
                                  golf_api_id='gapi-pebble').exists())

        # Idempotent: second open adds nothing new.
        resp2 = self.b_client.post(reverse('api-round-join', args=[self.round.id]))
        self.assertFalse(resp2.data['td_added'])
        self.assertFalse(resp2.data['course_added'])
        self.assertEqual(Player.objects.filter(account=self.acct_b).count(), 1)
        self.assertEqual(Course.objects.filter(account=self.acct_b).count(), 1)

    def test_join_blocked_for_non_participant(self):
        acct_c = Account.objects.create(name='Carl')
        carl = User.objects.create_user(username='carl', account=acct_c)
        carl.phone = '+19995550000'; carl.save(update_fields=['phone'])
        c = APIClient(); c.force_authenticate(carl)
        self.assertEqual(
            c.post(reverse('api-round-join', args=[self.round.id])).status_code,
            404)
