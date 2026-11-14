"""
api/test_player_unique_phone.py
-------------------------------
A phone number belongs to one golfer in an account (Paul, 14 Nov 2026).
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Player

User = get_user_model()


class UniquePhoneTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Phones Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.bill = Player.objects.create(
            account=self.acct, name='Bill Sinn', handicap_index=Decimal('12'),
            phone='(415) 555-0199')
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _create(self, **over):
        body = {'name': 'Someone', 'handicap_index': '10.0', 'phone': ''}
        body.update(over)
        return self.client.post(reverse('api-players'), body, format='json')

    def test_a_new_golfer_cannot_take_a_number_already_in_use(self):
        r = self._create(name='William', phone='(415) 555-0199')
        self.assertEqual(r.status_code, 400, r.data)
        self.assertIn("Bill Sinn's", r.data['detail'])
        self.assertEqual(r.data['existing_player_id'], self.bill.pk)
        self.assertEqual(Player.objects.filter(name='William').count(), 0)

    def test_the_same_number_written_another_way_is_the_same_number(self):
        for typed in ['+14155550199', '415-555-0199', '4155550199',
                      '1 (415) 555 0199']:
            r = self._create(name='X', phone=typed)
            self.assertEqual(r.status_code, 400, typed)

    def test_a_different_number_is_fine(self):
        self.assertEqual(self._create(name='A', phone='(415) 555-0200')
                         .status_code, 201)

    def test_golfers_with_no_number_do_not_conflict_with_each_other(self):
        self.assertEqual(self._create(name='A').status_code, 201)
        self.assertEqual(self._create(name='B').status_code, 201)

    def test_another_account_may_hold_the_same_number(self):
        other = Account.objects.create(name='Other Club')
        Player.objects.create(account=other, name='Bill Sinn',
                              handicap_index=Decimal('12'),
                              phone='(415) 555-0777')
        # A friend's copy of the same golfer is the whole point of the model.
        self.assertEqual(self._create(name='Bill', phone='(415) 555-0777')
                         .status_code, 201)

    def test_changing_a_golfers_number_to_one_in_use_is_refused(self):
        sam = Player.objects.create(account=self.acct, name='Sam',
                                    handicap_index=Decimal('8'),
                                    phone='(415) 555-0300')
        r = self.client.patch(reverse('api-player-detail', args=[sam.pk]),
                              {'phone': '(415) 555-0199'}, format='json')
        self.assertEqual(r.status_code, 400, r.data)
        sam.refresh_from_db()
        self.assertEqual(sam.phone, '(415) 555-0300')

    def test_an_unrelated_edit_is_not_refused_for_an_old_shared_number(self):
        # Two golfers already on one number (older data): editing something
        # else about either must still work.
        twin = Player.objects.create(account=self.acct, name='Twin',
                                     handicap_index=Decimal('9'),
                                     phone='(415) 555-0199')
        r = self.client.patch(reverse('api-player-detail', args=[twin.pk]),
                              {'handicap_index': '10.5'}, format='json')
        self.assertEqual(r.status_code, 200, r.data)

    def test_re_sending_a_golfers_own_number_is_not_a_conflict(self):
        r = self.client.patch(reverse('api-player-detail', args=[self.bill.pk]),
                              {'phone': '+14155550199', 'name': 'Bill Sinn'},
                              format='json')
        self.assertEqual(r.status_code, 200, r.data)

    def test_clearing_a_number_is_always_allowed(self):
        r = self.client.patch(reverse('api-player-detail', args=[self.bill.pk]),
                              {'phone': ''}, format='json')
        self.assertEqual(r.status_code, 200, r.data)
