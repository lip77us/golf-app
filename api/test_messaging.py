"""
api/test_messaging.py — round message feed (Phase 1).

Covers chat post/list, read state + unread, since-incremental fetch, the
reader-set authorization (non-participant 404), and event idempotency.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Round, Foursome, FoursomeMembership
from services import messaging

User = get_user_model()


def _account_with_round(name='Group A'):
    account = Account.objects.create(name=name)
    course = Course.objects.create(account=account, name='Pebble')
    user = User.objects.create_user(username=f'{name}-u'.lower().replace(' ', ''),
                                    account=account)
    player = Player.objects.create(
        account=account, name='Paul', user=user, handicap_index=Decimal('10.0'))
    rnd = Round.objects.create(account=account, course=course,
                               status='in_progress', active_games=['skins'])
    fs = Foursome.objects.create(round=rnd, group_number=1)
    FoursomeMembership.objects.create(
        foursome=fs, player=player, course_handicap=10, playing_handicap=10)
    return account, user, player, rnd


class RoundMessagesTests(TestCase):
    def setUp(self):
        self.account, self.user, self.player, self.round = _account_with_round()
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-round-messages', args=[self.round.id])
        self.read_url = reverse('api-round-messages-read', args=[self.round.id])

    def test_empty_feed(self):
        r = self.client.get(self.url)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['messages'], [])
        self.assertEqual(r.data['unread'], 0)
        self.assertEqual(r.data['my_player_id'], self.player.id)

    def test_post_and_list(self):
        r = self.client.post(self.url, {'body': 'Nice birdie!'}, format='json')
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data['body'], 'Nice birdie!')
        self.assertEqual(r.data['author_id'], self.player.id)
        self.assertEqual(r.data['kind'], 'user')

        r = self.client.get(self.url)
        self.assertEqual(len(r.data['messages']), 1)
        self.assertEqual(r.data['messages'][0]['author_name'], 'Paul')

    def test_empty_body_rejected(self):
        r = self.client.post(self.url, {'body': '   '}, format='json')
        self.assertEqual(r.status_code, 400)

    def test_own_posts_are_not_unread(self):
        self.client.post(self.url, {'body': 'one'}, format='json')
        self.client.post(self.url, {'body': 'two'}, format='json')
        self.assertEqual(self.client.get(self.url).data['unread'], 0)

    def test_unread_and_read_state_for_other_reader(self):
        m1 = self.client.post(self.url, {'body': 'one'}, format='json').data
        m2 = self.client.post(self.url, {'body': 'two'}, format='json').data

        # A second user in the same account reads the round → sees both unread.
        other = User.objects.create_user(username='u2', account=self.account)
        c2 = APIClient(); c2.force_authenticate(other)
        self.assertEqual(c2.get(self.url).data['unread'], 2)

        rr = c2.post(self.read_url, {'last_seen_id': m2['id']}, format='json')
        self.assertEqual(rr.status_code, 200)
        self.assertEqual(rr.data['unread'], 0)
        self.assertEqual(c2.get(self.url).data['unread'], 0)
        self.assertGreater(m2['id'], m1['id'])

    def test_since_incremental(self):
        a = self.client.post(self.url, {'body': 'a'}, format='json').data
        b = self.client.post(self.url, {'body': 'b'}, format='json').data
        r = self.client.get(self.url, {'since': a['id']})
        self.assertEqual([m['id'] for m in r.data['messages']], [b['id']])

    def test_non_participant_gets_404(self):
        _, other_user, _, _ = _account_with_round(name='Other Group')
        c = APIClient(); c.force_authenticate(other_user)
        self.assertEqual(c.get(self.url).status_code, 404)
        self.assertEqual(
            c.post(self.url, {'body': 'hi'}, format='json').status_code, 404)


class EventIdempotencyTests(TestCase):
    def test_post_event_is_idempotent(self):
        _, _, _, rnd = _account_with_round()
        thread = messaging.get_or_create_thread(rnd)
        m1 = messaging.post_event(thread, event_key='birdie:7:42',
                                  body='Paul made birdie on 7', data={'hole': 7})
        m2 = messaging.post_event(thread, event_key='birdie:7:42',
                                  body='dup', data={'hole': 7})
        self.assertEqual(m1.id, m2.id)
        self.assertEqual(thread.messages.count(), 1)
        self.assertEqual(m1.kind, 'event')
        self.assertIsNone(m1.author_id)
