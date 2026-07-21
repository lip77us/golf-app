"""
api/test_halved_lookup.py
-------------------------
Look up a registered Halved member so you can add them to a round even if
they're not in your roster yet.

Two modes with different privacy rules: ?phone= needs the full number and
ignores the discoverability opt-out, while ?name= is the only browsable path
into the member base and is fenced (min length, result cap, opt-out honoured).
Neither ever leaks contact info.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Account
from api.views import NAME_SEARCH_LIMIT, NAME_SEARCH_MIN_CHARS
from core.models import Course, Player


User = get_user_model()


class HalvedLookupTests(TestCase):
    def setUp(self):
        self.acct_b = Account.objects.create(name='Sam Account')
        self.sam = User.objects.create_user(username='sam', account=self.acct_b)
        self.sam.phone = '+13105550199'
        self.sam.save(update_fields=['phone'])
        Player.objects.create(
            account=self.acct_b, name='Sam Eyeballs', short_name='SE',
            phone='+13105550199', handicap_index=Decimal('8.0'), sex='M',
            user=self.sam)

        self.acct_a = Account.objects.create(name='Caller')
        self.caller = User.objects.create_user(username='cal', account=self.acct_a)
        self.c = APIClient(); self.c.force_authenticate(self.caller)

    def test_found_returns_profile_without_contact_info(self):
        r = self.c.get(reverse('api-halved-user-lookup'),
                       {'phone': '(310) 555-0199'})
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data['found'])
        self.assertEqual(r.data['name'], 'Sam Eyeballs')
        self.assertEqual(r.data['short_name'], 'SE')
        self.assertEqual(r.data['handicap_index'], '8.0')
        self.assertEqual(r.data['sex'], 'M')
        # Privacy: never echo contact details back.
        self.assertNotIn('phone', r.data)
        self.assertNotIn('email', r.data)

    def test_unknown_number(self):
        r = self.c.get(reverse('api-halved-user-lookup'),
                       {'phone': '+19998887777'})
        self.assertFalse(r.data['found'])

    def test_blank_number(self):
        r = self.c.get(reverse('api-halved-user-lookup'))
        self.assertFalse(r.data['found'])


class HalvedNameSearchTests(TestCase):
    """?name= — the browsable path, and the fences around it."""

    def setUp(self):
        self.acct_a = Account.objects.create(name='Caller')
        self.caller = User.objects.create_user(username='cal',
                                               account=self.acct_a)
        self.c = APIClient()
        self.c.force_authenticate(self.caller)

    def _member(self, username, name, phone, *, discoverable=True,
                verified=True, index='12.4', home_course=None, account=None):
        """A Halved member in their own account, optionally with a home course."""
        acct = account or Account.objects.create(name=f'{username} account')
        u = User.objects.create_user(username=username, account=acct)
        u.phone = phone
        u.discoverable_by_name = discoverable
        u.phone_verified_at = timezone.now() if verified else None
        u.save(update_fields=['phone', 'discoverable_by_name',
                              'phone_verified_at'])
        Player.objects.create(
            account=acct, name=name, short_name=name[:2].upper(), phone=phone,
            handicap_index=Decimal(index), sex='F', user=u,
            home_course=home_course)
        return u

    def _search(self, q):
        return self.c.get(reverse('api-halved-user-lookup'), {'name': q})

    def test_finds_member_by_partial_name(self):
        self._member('libby', 'Libby Chen', '+13105550101')
        r = self._search('Lib')
        self.assertEqual(r.status_code, 200)
        self.assertEqual([x['name'] for x in r.data['results']],
                         ['Libby Chen'])
        self.assertEqual(r.data['results'][0]['handicap_index'], '12.4')

    def test_never_returns_phone_or_email(self):
        self._member('libby', 'Libby Chen', '+13105550101')
        row = self._search('Lib').data['results'][0]
        self.assertNotIn('phone', row)
        self.assertNotIn('email', row)

    def test_location_comes_from_home_course(self):
        course = Course.objects.create(account=self.acct_a, name='Sequoyah',
                                       city='Oakland', state='CA')
        self._member('libby', 'Libby Chen', '+13105550101',
                     home_course=course)
        self.assertEqual(self._search('Lib').data['results'][0]['location'],
                         'Oakland, CA')

    def test_location_blank_without_home_course(self):
        self._member('libby', 'Libby Chen', '+13105550101')
        self.assertEqual(self._search('Lib').data['results'][0]['location'],
                         '')

    def test_short_query_is_refused(self):
        self._member('libby', 'Libby Chen', '+13105550101')
        r = self._search('Li' if NAME_SEARCH_MIN_CHARS == 3 else 'L')
        self.assertEqual(r.data['results'], [])
        self.assertIn('detail', r.data)

    def test_opted_out_member_is_invisible(self):
        self._member('libby', 'Libby Chen', '+13105550101',
                     discoverable=False)
        self.assertEqual(self._search('Lib').data['results'], [])

    def test_opted_out_member_is_still_findable_by_phone(self):
        """Knowing the number is its own proof of connection."""
        self._member('libby', 'Libby Chen', '+13105550101',
                     discoverable=False)
        r = self.c.get(reverse('api-halved-user-lookup'),
                       {'phone': '+13105550101'})
        self.assertTrue(r.data['found'])
        self.assertEqual(r.data['name'], 'Libby Chen')

    def test_unverified_member_is_invisible(self):
        self._member('libby', 'Libby Chen', '+13105550101', verified=False)
        self.assertEqual(self._search('Lib').data['results'], [])

    def test_caller_is_excluded(self):
        self.caller.phone = '+13105550100'
        self.caller.phone_verified_at = timezone.now()
        self.caller.save(update_fields=['phone', 'phone_verified_at'])
        Player.objects.create(
            account=self.acct_a, name='Libby Lipkin', short_name='LL',
            phone='+13105550100', handicap_index=Decimal('39.0'), sex='F',
            user=self.caller)
        self.assertEqual(self._search('Lib').data['results'], [])

    def test_existing_roster_golfer_is_excluded(self):
        """The client already lists these under "Your golfers"."""
        member = self._member('libby', 'Libby Chen', '+13105550101')
        Player.objects.create(
            account=self.acct_a, name='Libby C', short_name='LC',
            phone=member.phone, handicap_index=Decimal('12.4'), sex='F')
        self.assertEqual(self._search('Lib').data['results'], [])

    def test_roster_golfer_excluded_despite_phone_formatting(self):
        """
        Roster numbers are stored as typed; a member's login phone is E.164.
        Comparing them raw matches nothing, and the golfer you already have
        comes back as a stranger to add all over again.
        """
        self._member('libby', 'Libby Chen', '+13105550101')
        Player.objects.create(
            account=self.acct_a, name='Libby C', short_name='LC',
            phone='(310) 555-0101',  # same human, typed by hand
            handicap_index=Decimal('12.4'), sex='F')
        self.assertEqual(self._search('Lib').data['results'], [])

    def test_results_are_capped(self):
        for i in range(NAME_SEARCH_LIMIT + 5):
            self._member(f'lib{i}', f'Libby Number{i:02d}',
                         f'+1310555{i:04d}')
        self.assertEqual(len(self._search('Libby').data['results']),
                         NAME_SEARCH_LIMIT)


class AddHalvedGolferToRosterTests(TestCase):
    """
    Adding a name-search result to My Golfers.

    The point of doing this server-side is that name search never returns a
    phone number, and the phone is what links a roster Player to the member —
    it carries their handicap and it is how search knows to stop offering
    someone you already have.
    """

    def setUp(self):
        self.acct = Account.objects.create(name='Caller')
        self.caller = User.objects.create_user(username='cal',
                                               account=self.acct)
        # Every phone-OTP signup is an admin of its own account; roster
        # creation is admin-only.
        self.caller.is_account_admin = True
        self.caller.save(update_fields=['is_account_admin'])
        self.c = APIClient()
        self.c.force_authenticate(self.caller)

        self.member_acct = Account.objects.create(name='Libby account')
        self.member = User.objects.create_user(username='libby',
                                               account=self.member_acct)
        self.member.phone = '+13105550101'
        self.member.phone_verified_at = timezone.now()
        self.member.save(update_fields=['phone', 'phone_verified_at'])
        Player.objects.create(
            account=self.member_acct, name='Libby Chen', short_name='LC',
            phone='+13105550101', handicap_index=Decimal('12.4'), sex='F',
            user=self.member)

    def _add(self, uid):
        return self.c.post(reverse('api-halved-user-add-to-roster'),
                           {'id': uid}, format='json')

    def test_creates_roster_player_carrying_the_phone_link(self):
        r = self._add(self.member.pk)
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data['name'], 'Libby Chen')
        mine = Player.objects.get(account=self.acct, name='Libby Chen')
        # The link the client could not have made itself.
        self.assertEqual(mine.phone, '+13105550101')
        self.assertEqual(mine.handicap_index, Decimal('12.4'))
        self.assertEqual(mine.sex, 'F')

    def test_added_golfer_stops_appearing_in_search(self):
        """The whole reason the phone has to come across."""
        url = reverse('api-halved-user-lookup')
        self.assertEqual(len(self.c.get(url, {'name': 'Lib'}).data['results']),
                         1)
        self._add(self.member.pk)
        self.assertEqual(self.c.get(url, {'name': 'Lib'}).data['results'], [])

    def test_matches_an_existing_roster_golfer_despite_formatting(self):
        """
        Adding someone you already hold under a hand-typed number must return
        that golfer, not mint a second copy of the same person.
        """
        mine = Player.objects.create(
            account=self.acct, name='Libby C', short_name='LC',
            phone='(310) 555-0101', handicap_index=Decimal('12.4'), sex='F')
        r = self._add(self.member.pk)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['id'], mine.pk)
        self.assertEqual(Player.objects.filter(account=self.acct).count(), 1)

    def test_is_idempotent(self):
        first = self._add(self.member.pk)
        second = self._add(self.member.pk)
        self.assertEqual(second.status_code, 200)
        self.assertEqual(first.data['id'], second.data['id'])
        self.assertEqual(
            Player.objects.filter(account=self.acct, phone=self.member.phone)
            .count(), 1)

    def test_phone_is_stored_but_never_shown(self):
        """
        The number has to be in the row (it is the join key) and must not be
        in the response — the caller found this member by name and still has
        no business knowing their number.
        """
        r = self._add(self.member.pk)
        self.assertEqual(r.data['phone'], '')
        mine = Player.objects.get(account=self.acct, name='Libby Chen')
        self.assertEqual(mine.phone, '+13105550101')
        self.assertTrue(mine.phone_from_directory)

    def test_hidden_phone_survives_a_roster_listing(self):
        self._add(self.member.pk)
        rows = self.c.get(reverse('api-players')).data
        row = next(r for r in rows if r['name'] == 'Libby Chen')
        self.assertEqual(row['phone'], '')
        # ...and the Halved badge still lights up, because is_on_app is
        # computed server-side from the phone match.
        self.assertTrue(row['is_on_app'])

    def test_saving_the_player_form_cannot_wipe_the_link(self):
        """
        The client shows a blank phone for these golfers, so a plain save must
        not PATCH the real number away and silently break the member link.
        """
        self._add(self.member.pk)
        mine = Player.objects.get(account=self.acct, name='Libby Chen')
        r = self.c.patch(reverse('api-player-detail', args=[mine.pk]),
                         {'name': 'Libby C.', 'phone': ''}, format='json')
        self.assertEqual(r.status_code, 200)
        mine.refresh_from_db()
        self.assertEqual(mine.name, 'Libby C.')
        self.assertEqual(mine.phone, '+13105550101')
        self.assertTrue(mine.phone_from_directory)

    def test_owner_typing_a_real_number_takes_over(self):
        """Once they know it themselves, there is nothing left to hide."""
        self._add(self.member.pk)
        mine = Player.objects.get(account=self.acct, name='Libby Chen')
        self.c.patch(reverse('api-player-detail', args=[mine.pk]),
                     {'phone': '+13105559999'}, format='json')
        mine.refresh_from_db()
        self.assertEqual(mine.phone, '+13105559999')
        self.assertFalse(mine.phone_from_directory)

    def test_non_admin_cannot_add(self):
        self.caller.is_account_admin = False
        self.caller.save(update_fields=['is_account_admin'])
        self.assertEqual(self._add(self.member.pk).status_code, 403)

    def test_opted_out_member_cannot_be_added(self):
        """A stale id from before they opted out must not still work."""
        self.member.discoverable_by_name = False
        self.member.save(update_fields=['discoverable_by_name'])
        self.assertEqual(self._add(self.member.pk).status_code, 404)

    def test_unknown_id(self):
        self.assertEqual(self._add(999999).status_code, 404)

    def test_missing_id(self):
        r = self.c.post(reverse('api-halved-user-add-to-roster'), {},
                        format='json')
        self.assertEqual(r.status_code, 400)

    def test_cannot_add_yourself(self):
        self.caller.phone = '+13105550100'
        self.caller.phone_verified_at = timezone.now()
        self.caller.save(update_fields=['phone', 'phone_verified_at'])
        self.assertEqual(self._add(self.caller.pk).status_code, 404)


class DiscoverabilityToggleTests(TestCase):
    """PATCH /api/auth/me/ — the profile + signup opt-out."""

    def setUp(self):
        self.acct = Account.objects.create(name='Caller')
        self.user = User.objects.create_user(username='cal', account=self.acct)
        self.c = APIClient()
        self.c.force_authenticate(self.user)

    def test_defaults_to_discoverable(self):
        self.assertTrue(self.user.discoverable_by_name)
        self.assertTrue(self.c.get(reverse('api-me')).data[
            'discoverable_by_name'])

    def test_can_opt_out_and_back_in(self):
        r = self.c.patch(reverse('api-me'),
                         {'discoverable_by_name': False}, format='json')
        self.assertEqual(r.status_code, 200)
        self.user.refresh_from_db()
        self.assertFalse(self.user.discoverable_by_name)

        self.c.patch(reverse('api-me'),
                     {'discoverable_by_name': True}, format='json')
        self.user.refresh_from_db()
        self.assertTrue(self.user.discoverable_by_name)

    def test_rejects_non_boolean(self):
        r = self.c.patch(reverse('api-me'),
                         {'discoverable_by_name': 'nope'}, format='json')
        self.assertEqual(r.status_code, 400)
        self.user.refresh_from_db()
        self.assertTrue(self.user.discoverable_by_name)

    def test_patch_cannot_touch_other_fields(self):
        """Allow-list, not a blanket serializer update."""
        r = self.c.patch(reverse('api-me'),
                         {'is_staff': True}, format='json')
        self.assertEqual(r.status_code, 400)
        self.user.refresh_from_db()
        self.assertFalse(self.user.is_staff)
