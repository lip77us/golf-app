"""
api/test_genius_import.py
-------------------------
Golf Genius roster import (services/genius_import.py): CSV parsing, phone/GHIN
matching, the create/update/skip plan, and atomic apply.

Uses a small in-memory CSV (same header labels as a real Golf Genius export,
with a leading title-banner row) so no fixture file is needed.
"""
from decimal import Decimal

from django.test import TestCase

from accounts.models import Account
from core.models import Player
from services import genius_import as gi


CSV = (
    "Tilden Seniors GC, Version 1\n"                       # title banner row
    "Email,First Name,Last Name,Index,GHIN Id,Phone Number,Gender\n"
    "match@x.com,Match,Byphone,10.4,,(415) 555-0100,M\n"   # matches existing by phone
    "ghin@x.com,Match,Byghin,8.0,7654321,,M\n"             # matches existing by GHIN
    "new@x.com,Nora,Newcomer,+1.2,1112223,415-555-0200,F\n"  # new golfer, plus handicap
    "noidx@x.com,Nathan,Noindex,NH,9998887,415-555-0201,M\n"  # new but no index -> skip
    "same@x.com,Sam,Same,14.0,,415-555-0102,M\n"           # existing, no change
)


class GeniusParseTests(TestCase):
    def test_parse_index_handles_plus_and_sentinels(self):
        self.assertEqual(gi.parse_index('12.3'), Decimal('12.3'))
        self.assertEqual(gi.parse_index('+2.4'), Decimal('-2.4'))   # plus handicap
        self.assertEqual(gi.parse_index('0'), Decimal('0'))
        self.assertIsNone(gi.parse_index('NH'))
        self.assertIsNone(gi.parse_index(''))
        self.assertIsNone(gi.parse_index('WD'))

    def test_finds_header_below_title_banner(self):
        rows = gi.read_rows('roster.csv', CSV.encode())
        parsed, hmap = gi.parse_rows(rows)
        self.assertEqual(hmap['first name'], 1)
        # 5 data rows (banner + header stripped)
        self.assertEqual(len(parsed), 5)

    def test_unsupported_extension_rejected(self):
        with self.assertRaises(ValueError):
            gi.read_rows('roster.txt', b'nope')


class GeniusPlanApplyTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Plan Test')
        # Existing roster: one matchable by phone, one by GHIN, one unchanged.
        self.byphone = Player.objects.create(
            account=self.account, name='Old Phone',
            phone='+14155550100', handicap_index=Decimal('20.0'))
        self.byghin = Player.objects.create(
            account=self.account, name='Old Ghin', ghin='7654321',
            handicap_index=Decimal('9.9'))
        # Already has the CSV's email + index, so the import finds nothing to
        # change -> lands in the "unchanged" bucket.
        self.same = Player.objects.create(
            account=self.account, name='Sam Same', email='same@x.com',
            phone='(415) 555-0102', handicap_index=Decimal('14.0'))

        rows = gi.read_rows('roster.csv', CSV.encode())
        self.parsed, _ = gi.parse_rows(rows)
        self.plan = gi.build_plan(self.account, self.parsed)

    def test_plan_buckets(self):
        s = self.plan.summary()
        self.assertEqual(s['create'], 1)      # Nora Newcomer
        self.assertEqual(s['update'], 2)      # matched by phone + by ghin
        self.assertEqual(s['unchanged'], 1)   # Sam Same
        self.assertEqual(s['skipped'], 1)     # Nathan (no index, new)

    def test_skip_reason_is_no_index(self):
        reasons = [sk.reason for sk in self.plan.skipped]
        self.assertEqual(reasons, ['new golfer has no index'])

    def test_phone_match_updates_index(self):
        upd = {u.player_id: u.changes for u in self.plan.to_update}
        self.assertIn('handicap_index', upd[self.byphone.id])
        self.assertEqual(upd[self.byphone.id]['handicap_index'], Decimal('10.4'))

    def test_ghin_match_updates_index(self):
        upd = {u.player_id: u.changes for u in self.plan.to_update}
        self.assertEqual(upd[self.byghin.id]['handicap_index'], Decimal('8.0'))

    def test_apply_writes(self):
        created, updated = gi.apply_plan(self.account, self.plan)
        self.assertEqual((created, updated), (1, 2))

        self.byphone.refresh_from_db()
        self.assertEqual(self.byphone.handicap_index, Decimal('10.4'))

        nora = Player.objects.get(account=self.account, name='Nora Newcomer')
        self.assertEqual(nora.handicap_index, Decimal('-1.2'))   # plus handicap
        self.assertEqual(nora.ghin, '1112223')
        self.assertEqual(nora.sex, 'W')
        self.assertEqual(gi.normalize_phone(nora.phone), '+14155550200')

    def test_apply_is_idempotent(self):
        gi.apply_plan(self.account, self.plan)
        # Re-planning after apply -> nothing left to create/update.
        rows = gi.read_rows('roster.csv', CSV.encode())
        parsed, _ = gi.parse_rows(rows)
        plan2 = gi.build_plan(self.account, parsed)
        s = plan2.summary()
        self.assertEqual(s['create'], 0)
        self.assertEqual(s['update'], 0)
