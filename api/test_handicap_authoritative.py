"""
api/test_handicap_authoritative.py
----------------------------------
A connected ("On Halved") golfer's handicap follows them: their own profile is
authoritative, so a friend's local copy resolves to the golfer's self-maintained
index for both DISPLAY (serializer) and COMPUTATION (course handicap at setup).
Login-less guests keep their locally-typed value.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee


User = get_user_model()


class AuthoritativeHandicapTests(TestCase):
    def setUp(self):
        # Sam owns his profile (handicap 8.0) in his own account.
        self.acct_b = Account.objects.create(name='Sam Account')
        self.sam = User.objects.create_user(username='sam', account=self.acct_b)
        self.sam.phone = '+13105550199'
        self.sam.save(update_fields=['phone'])
        self.sam_profile = Player.objects.create(
            account=self.acct_b, name='Sam', phone='+13105550199',
            handicap_index=Decimal('8.0'), user=self.sam)

        # A friend's account with a STALE local copy of Sam (handicap 20.0).
        self.acct_a = Account.objects.create(name='Friend Account')
        self.friend = User.objects.create_user(username='fred', account=self.acct_a)
        self.friend.phone = '+13105550111'
        self.friend.save(update_fields=['phone'])
        self.sam_copy = Player.objects.create(
            account=self.acct_a, name='Sam Eyeballs', phone='(310) 555-0199',
            handicap_index=Decimal('20.0'))
        self.a_client = APIClient(); self.a_client.force_authenticate(self.friend)

    def test_effective_index_follows_owner(self):
        self.assertEqual(self.sam_copy.effective_handicap_index(), Decimal('8.0'))

    def test_course_handicap_uses_authoritative(self):
        course = Course.objects.create(account=self.acct_a, name='X')
        tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, sex='M',
            sort_priority=0, holes=[])
        # slope 113 + rating==par → course handicap == index; 8 (not the stale 20).
        self.assertEqual(self.sam_copy.course_handicap(tee), 8)

    def test_serializer_shows_authoritative(self):
        resp = self.a_client.get(reverse('api-players'))
        row = next(p for p in resp.data if p['name'] == 'Sam Eyeballs')
        self.assertEqual(row['effective_handicap_index'], '8.0')
        self.assertTrue(row['is_on_app'])
        self.assertTrue(row['handicap_is_authoritative'])

    def test_owner_unset_index_falls_back_to_local(self):
        # Sam hasn't set a real index (0) → his friend's local value is kept,
        # and stays editable (not authoritative).
        self.sam_profile.handicap_index = Decimal('0.0')
        self.sam_profile.save(update_fields=['handicap_index'])
        self.assertEqual(self.sam_copy.effective_handicap_index(),
                         Decimal('20.0'))
        resp = self.a_client.get(reverse('api-players'))
        row = next(p for p in resp.data if p['name'] == 'Sam Eyeballs')
        self.assertEqual(row['effective_handicap_index'], '20.0')
        self.assertFalse(row['handicap_is_authoritative'])

    def test_login_less_guest_keeps_local(self):
        guest = Player.objects.create(
            account=self.acct_a, name='Walk On', phone='',
            handicap_index=Decimal('14.0'))
        self.assertEqual(guest.effective_handicap_index(), Decimal('14.0'))

    def test_own_profile_no_self_loop(self):
        self.assertEqual(self.sam_profile.effective_handicap_index(),
                         Decimal('8.0'))
