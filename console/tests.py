"""
console/tests.py
----------------
TD console — sign-in and the Golf Genius import.

The OTP tests drive the REAL issue/verify path (``accounts.otp`` on the local
backend, hashed codes in ``PhoneOTP``) and capture the code by patching the SMS
sender, rather than stubbing out verification.  The point of these tests is the
two promises the web flow adds on top of the app's: **no account is ever
created here**, and a wrong code counts down out loud.

The import tests assert the things that would break silently — that a preview
writes nothing, that the plan is rebuilt from TD-typed values, that a plus
handicap never reaches the screen as a negative, and that applying twice
cannot double-write.
"""

import re
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.urls import reverse
from unittest.mock import patch

from accounts.models import Account
from core.models import Player

from .models import ImportRun


User = get_user_model()

# Production serves static through whitenoise's manifest storage, which refuses
# to resolve a name that isn't in the collectstatic manifest.  These tests
# render real templates and care about their content, not their asset URLs.
plain_static = override_settings(STORAGES={
    'staticfiles': {
        'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'},
})

# A Golf Genius export in miniature: a title banner above the header, one row
# per case the preview has to render.
CSV = (
    "Tilden Seniors GC, Version 1\n"
    "Email,First Name,Last Name,Index,GHIN Id,Phone Number,Gender\n"
    "dave@x.com,Dave,Moran,7.9,,(415) 555-0100,M\n"        # 3 update, matched on phone
    "lee@x.com,Lee,Naylor,14.2,7654321,415-555-0114,M\n"   # 4 update, matched on GHIN
    "theo@x.com,Theo,Barnes,+2.3,2210047,415-555-0290,M\n" # 5 create, plus handicap
    "alan@x.com,Alan,Pryce,NH,1112223,415-555-0201,M\n"    # 6 skip, no index (cell "NH")
    "sam@x.com,Sam,Same,14.0,,415-555-0102,M\n"            # 7 unchanged
    ",,,12.0,,415-555-0303,M\n"                            # 8 skip, no name at all
    "ken@x.com,Ken,Iverson,62.1,,415-555-0404,M\n"         # 9 skip, index out of range
)


def _sms_capture():
    """Patch the SMS sender and hand back the list it appends codes to."""
    sent = []

    def fake_send(phone, body):
        sent.append((phone, body))

    return sent, patch('accounts.otp.send_sms', side_effect=fake_send)


def _code_from(sent):
    return re.search(r'\b(\d{6})\b', sent[-1][1]).group(1)


@plain_static
class SignInTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Tilden')
        self.user = User.objects.create_user(
            username='paul', account=self.account, is_account_admin=True)
        self.user.phone = '+14155550148'
        self.user.save()

    def test_unknown_number_is_a_dead_end_and_sends_nothing(self):
        """No account is created on the web, and saying so costs no SMS."""
        sent, patcher = _sms_capture()
        with patcher:
            resp = self.client.post(reverse('console:sign-in'),
                                    {'phone': '415-555-9999'})
        self.assertEqual(resp.status_code, 200)          # re-rendered, not redirected
        self.assertContains(resp, 'Create your account in the Halved app')
        self.assertEqual(sent, [])
        self.assertEqual(Account.objects.count(), 1)     # nothing self-created
        self.assertEqual(User.objects.count(), 1)

    def test_known_number_signs_in_and_lands_on_import(self):
        sent, patcher = _sms_capture()
        with patcher:
            resp = self.client.post(reverse('console:sign-in'),
                                    {'phone': '(415) 555-0148'})
            self.assertRedirects(resp, reverse('console:sign-in-code'))
            resp = self.client.post(reverse('console:sign-in-code'), {
                'digit': list(_code_from(sent)), 'remember': '1'})
        # Verify lands on Import roster, not a dashboard.
        self.assertRedirects(resp, reverse('console:import'))
        self.assertEqual(self.client.session['_auth_user_id'], str(self.user.pk))

    def test_wrong_code_counts_the_tries_left(self):
        sent, patcher = _sms_capture()
        with patcher:
            self.client.post(reverse('console:sign-in'), {'phone': '4155550148'})
            resp = self.client.post(reverse('console:sign-in-code'),
                                    {'digit': list('000000')})
        self.assertContains(resp, 'Two tries left')
        self.assertNotIn('_auth_user_id', self.client.session)

    def test_third_wrong_code_spends_it(self):
        sent, patcher = _sms_capture()
        with patcher:
            self.client.post(reverse('console:sign-in'), {'phone': '4155550148'})
            for _ in range(2):
                self.client.post(reverse('console:sign-in-code'),
                                 {'digit': list('000000')})
            resp = self.client.post(reverse('console:sign-in-code'),
                                    {'digit': list('000000')})
        self.assertContains(resp, 'now spent')

    def test_signed_out_visit_is_sent_to_sign_in_and_the_screen_is_remembered(self):
        resp = self.client.get(reverse('console:import'))
        self.assertRedirects(resp, reverse('console:sign-in'))
        # State 5 promises the notice names the screen you were thrown off.
        self.assertContains(self.client.get(reverse('console:sign-in')),
                            'Import roster')

    def test_keep_me_signed_in_controls_the_cookie_life(self):
        """On by default, 30 days; unchecked falls back to browser-session."""
        for remember, expect_browser_close in ((True, False), (False, True)):
            with self.subTest(remember=remember):
                self.client.logout()
                sent, patcher = _sms_capture()
                with patcher:
                    self.client.post(reverse('console:sign-in'),
                                     {'phone': '4155550148'})
                    post = {'digit': list(_code_from(sent))}
                    if remember:
                        post['remember'] = '1'
                    self.client.post(reverse('console:sign-in-code'), post)
                session = self.client.session
                self.assertEqual(session.get_expire_at_browser_close(),
                                 expect_browser_close)
                if remember:
                    self.assertEqual(session.get_expiry_age(), 30 * 24 * 60 * 60)


@plain_static
class ImportTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Tilden')
        self.user = User.objects.create_user(
            username='paul', account=self.account, is_account_admin=True)
        self.client.force_login(
            self.user, backend='accounts.backends.AccountBackend')

        # Existing roster: one matchable by phone, one by GHIN (with no phone,
        # so the import backfills it), one already correct.
        self.dave = Player.objects.create(
            account=self.account, name='Dave Moran', phone='+14155550100',
            email='dave@x.com', handicap_index=Decimal('8.4'))
        self.lee = Player.objects.create(
            account=self.account, name='Lee Naylor', ghin='7654321',
            email='lee@x.com', handicap_index=Decimal('15.0'))
        Player.objects.create(
            account=self.account, name='Sam Same', phone='+14155550102',
            email='sam@x.com', handicap_index=Decimal('14.0'))

    # -- helpers ------------------------------------------------------------

    def _upload(self, body=CSV, name='roster.csv'):
        return self.client.post(reverse('console:import'), {
            'file': SimpleUploadedFile(name, body.encode(),
                                       content_type='text/csv')})

    def _preview(self):
        self._upload()
        run = ImportRun.objects.get()
        return run, self.client.get(
            reverse('console:import-preview', args=[run.pk]))

    # -- the dry run --------------------------------------------------------

    def test_upload_previews_and_writes_nothing(self):
        before = Player.objects.count()
        run, resp = self._preview()

        self.assertEqual(run.status, ImportRun.STATUS_PREVIEW)
        self.assertIsNone(run.number)                 # a draft burns no number
        self.assertEqual(Player.objects.count(), before)
        self.assertContains(resp, 'DRY RUN')
        # The header scan is reported, because pointing it at the wrong sheet
        # fails silently.
        self.assertEqual(run.header_line, 2)
        self.assertContains(resp, 'Header found on row 2')

    def test_preview_shows_the_key_that_matched_and_field_level_diffs(self):
        _, resp = self._preview()
        body = resp.content.decode()
        self.assertIn('PHONE', body)                  # Dave matched on phone
        self.assertIn('GHIN', body)                   # Lee matched on GHIN
        self.assertIn('8.4', body)                    # idx 8.4 -> 7.9
        self.assertIn('7.9', body)
        self.assertIn('(was blank)', body)            # Lee's phone is a backfill

    def test_plus_handicap_is_shown_the_way_it_is_written(self):
        """Stored as -2.3; on screen it must read +2.3 or it looks like a bug."""
        _, resp = self._preview()
        self.assertContains(resp, '+2.3')
        self.assertNotContains(resp, '-2.3')

    def test_skip_reasons_are_sentences_and_quote_the_cell(self):
        _, resp = self._preview()
        self.assertContains(resp, 'New golfer has no index')
        self.assertContains(resp, 'index cell read')      # ...&ldquo;NH&rdquo;
        self.assertContains(resp, 'No name')
        self.assertContains(resp, 'out of range')

    def test_apply_button_carries_the_counts(self):
        _, resp = self._preview()
        self.assertContains(resp, 'Apply — create 1, update 2')

    # -- inline index entry -------------------------------------------------

    def test_typed_index_moves_a_skipped_row_into_create(self):
        run, _ = self._preview()
        url = reverse('console:import-preview', args=[run.pk])

        resp = self.client.post(url, {'action': 'index', 'line': '6',
                                      'index': '11.4'})
        self.assertRedirects(resp, url)

        run.refresh_from_db()
        self.assertEqual(run.overrides, {'6': '11.4'})
        self.assertEqual(Player.objects.count(), 3)       # still a dry run
        # Alan Pryce is now a create, so the button says two.
        self.assertContains(self.client.get(url), 'Apply — create 2, update 2')

    def test_an_unusable_typed_index_is_rejected_not_stored(self):
        run, _ = self._preview()
        url = reverse('console:import-preview', args=[run.pk])
        # "WD" means leave it skipped; 99 is outside the model's bounds.
        for bad in ('WD', '99'):
            self.client.post(url, {'action': 'index', 'line': '6', 'index': bad})
            run.refresh_from_db()
            self.assertEqual(run.overrides, {})

    # -- apply --------------------------------------------------------------

    def test_apply_writes_once_and_keeps_a_numbered_receipt(self):
        run, _ = self._preview()
        url = reverse('console:import-preview', args=[run.pk])

        resp = self.client.post(url, {'action': 'apply'})
        run.refresh_from_db()
        self.assertEqual(run.status, ImportRun.STATUS_APPLIED)
        self.assertEqual(run.number, 1)
        self.assertRedirects(resp, reverse('console:import-run', args=[1]))

        self.dave.refresh_from_db()
        self.lee.refresh_from_db()
        self.assertEqual(self.dave.handicap_index, Decimal('7.9'))
        self.assertEqual(self.lee.handicap_index, Decimal('14.2'))
        self.assertEqual(self.lee.phone, '+14155550114')   # backfilled
        self.assertTrue(Player.objects.filter(name='Theo Barnes').exists())

        receipt = self.client.get(reverse('console:import-run', args=[1]))
        self.assertContains(receipt, 'Kept as run #1')
        # The receipt states what is STILL wrong, not just what changed.
        self.assertContains(receipt, 'has no name')
        # No undo button, because the importer has no undo.
        self.assertNotContains(receipt, 'Undo')

    def test_applying_twice_is_refused(self):
        run, _ = self._preview()
        url = reverse('console:import-preview', args=[run.pk])
        self.client.post(url, {'action': 'apply'})
        created = Player.objects.count()

        # The preview URL now redirects to the receipt rather than re-applying.
        resp = self.client.post(url, {'action': 'apply'})
        self.assertRedirects(resp, reverse('console:import-run', args=[1]))
        self.assertEqual(Player.objects.count(), created)

    def test_apply_is_one_transaction(self):
        """A failure part-way writes nothing at all."""
        run, _ = self._preview()
        url = reverse('console:import-preview', args=[run.pk])
        before = Player.objects.count()

        with patch('core.models.Player.objects.get',
                   side_effect=RuntimeError('boom')):
            with self.assertRaises(RuntimeError):
                self.client.post(url, {'action': 'apply'})

        self.assertEqual(Player.objects.count(), before)
        run.refresh_from_db()
        self.assertEqual(run.status, ImportRun.STATUS_PREVIEW)

    def test_discard_leaves_the_roster_alone(self):
        run, _ = self._preview()
        self.client.post(reverse('console:import-preview', args=[run.pk]),
                         {'action': 'discard'})
        run.refresh_from_db()
        self.assertEqual(run.status, ImportRun.STATUS_DISCARDED)
        self.assertEqual(Player.objects.count(), 3)

    def test_run_csv_lists_every_row_and_what_happened_to_it(self):
        run, _ = self._preview()
        self.client.post(reverse('console:import-preview', args=[run.pk]),
                         {'action': 'apply'})
        resp = self.client.get(reverse('console:import-run-csv', args=[1]))
        body = resp.content.decode()
        self.assertEqual(resp['Content-Type'], 'text/csv')
        for token in ('created', 'updated', 'skipped', 'unchanged'):
            self.assertIn(token, body)

    # -- guards -------------------------------------------------------------

    def test_a_non_admin_gets_the_empty_state_not_a_rejection(self):
        member = User.objects.create_user(
            username='member', account=self.account, is_account_admin=False)
        self.client.force_login(
            member, backend='accounts.backends.AccountBackend')
        resp = self.client.get(reverse('console:import'))
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, 'No roster to manage')
        self.assertNotContains(resp, 'Drop the export here')

    def test_another_accounts_run_is_not_reachable(self):
        run, _ = self._preview()
        other = Account.objects.create(name='Somebody Else')
        intruder = User.objects.create_user(
            username='them', account=other, is_account_admin=True)
        self.client.force_login(
            intruder, backend='accounts.backends.AccountBackend')
        resp = self.client.get(
            reverse('console:import-preview', args=[run.pk]))
        self.assertEqual(resp.status_code, 404)

    def test_a_file_with_no_header_is_refused_with_a_reason(self):
        resp = self._upload(body='just,some,columns\n1,2,3\n')
        self.assertEqual(ImportRun.objects.count(), 0)
        self.assertContains(resp, 'First Name')

    def test_an_unsupported_extension_is_refused(self):
        resp = self._upload(name='roster.txt')
        self.assertEqual(ImportRun.objects.count(), 0)
        self.assertContains(resp, 'use a .csv or .xlsx export')
