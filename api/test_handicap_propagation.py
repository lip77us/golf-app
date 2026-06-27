"""
api/test_handicap_propagation.py
--------------------------------
Handicap-index model: every account keeps its OWN editable copy of a golfer's
index (a friend can ALWAYS change their copy).  When a registered golfer edits
their OWN profile index, it PROPAGATES (push) to their friends' login-less
copies, matched by normalized phone.  No read-time override / lock.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee


User = get_user_model()


def _admin(account, username, phone=None):
    u = User.objects.create_user(username=username, account=account)
    u.is_account_admin = True
    if phone:
        u.phone = phone
    u.save(update_fields=['is_account_admin', 'phone'] if phone
           else ['is_account_admin'])
    return u


class HandicapPropagationTests(TestCase):
    def setUp(self):
        # Sam owns his profile (index 8.0) in his own account.
        self.acct_b = Account.objects.create(name='Sam Account')
        self.sam = _admin(self.acct_b, 'sam', phone='+13105550199')
        self.sam_profile = Player.objects.create(
            account=self.acct_b, name='Sam', phone='+13105550199',
            handicap_index=Decimal('8.0'), user=self.sam)

        # A friend's account with its OWN copy of Sam (formatted phone, index 20).
        self.acct_a = Account.objects.create(name='Friend Account')
        self.fred = _admin(self.acct_a, 'fred', phone='+13105550111')
        self.sam_copy = Player.objects.create(
            account=self.acct_a, name='Sam Eyeballs', phone='(310) 555-0199',
            handicap_index=Decimal('20.0'))

        self.a_client = APIClient(); self.a_client.force_authenticate(self.fred)
        self.b_client = APIClient(); self.b_client.force_authenticate(self.sam)

    # ── read side: the local copy is the source of truth ──────────────────
    def test_copy_uses_its_own_local_index(self):
        self.assertEqual(self.sam_copy.effective_handicap_index(), Decimal('20.0'))

    def test_course_handicap_uses_local(self):
        course = Course.objects.create(account=self.acct_a, name='X')
        tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, sex='M',
            sort_priority=0, holes=[])
        # slope 113 + rating==par → course handicap == index → local 20, not 8.
        self.assertEqual(self.sam_copy.course_handicap(tee), 20)

    def test_serializer_shows_local_and_is_editable(self):
        resp = self.a_client.get(reverse('api-players'))
        row = next(p for p in resp.data if p['name'] == 'Sam Eyeballs')
        self.assertEqual(row['handicap_index'], '20.0')  # local copy shown
        self.assertTrue(row['is_on_app'])                # badge still works

    # ── friend can always change their copy; it stays local ───────────────
    def test_friend_edit_is_local_no_propagation(self):
        resp = self.a_client.patch(
            reverse('api-player-detail', args=[self.sam_copy.id]),
            {'handicap_index': '12.3'}, format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.sam_copy.refresh_from_db()
        self.sam_profile.refresh_from_db()
        self.assertEqual(self.sam_copy.handicap_index, Decimal('12.3'))
        self.assertEqual(self.sam_profile.handicap_index, Decimal('8.0'))  # unchanged

    # ── owner editing their OWN index propagates to copies ────────────────
    def test_owner_edit_propagates_to_copies(self):
        resp = self.b_client.patch(
            reverse('api-player-detail', args=[self.sam_profile.id]),
            {'handicap_index': '5.0'}, format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.sam_copy.refresh_from_db()
        self.assertEqual(self.sam_copy.handicap_index, Decimal('5.0'))

    def test_owner_edit_overwrites_friend_local_change(self):
        # Friend tweaks their copy, THEN the owner changes their own index:
        # the owner's value wins (overwrites the copy).
        self.sam_copy.handicap_index = Decimal('15.0')
        self.sam_copy.save(update_fields=['handicap_index'])
        self.b_client.patch(
            reverse('api-player-detail', args=[self.sam_profile.id]),
            {'handicap_index': '6.0'}, format='json')
        self.sam_copy.refresh_from_db()
        self.assertEqual(self.sam_copy.handicap_index, Decimal('6.0'))

    def test_owner_edit_only_touches_phone_matches(self):
        # An unrelated guest with a different phone is never affected.
        other = Player.objects.create(
            account=self.acct_a, name='Someone Else', phone='(310) 555-0000',
            handicap_index=Decimal('30.0'))
        self.b_client.patch(
            reverse('api-player-detail', args=[self.sam_profile.id]),
            {'handicap_index': '7.0'}, format='json')
        other.refresh_from_db()
        self.assertEqual(other.handicap_index, Decimal('30.0'))

    def test_login_less_guest_keeps_local(self):
        guest = Player.objects.create(
            account=self.acct_a, name='Walk On', phone='',
            handicap_index=Decimal('14.0'))
        self.assertEqual(guest.effective_handicap_index(), Decimal('14.0'))
