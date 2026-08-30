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


class SharedPhoneTests(TestCase):
    """Two golfers on one phone — the older-couple-with-a-home-phone case.

    Real data: Charlie Han had no index and was skipped, but had already
    claimed the shared number, so Diana Han was dropped as a duplicate of a
    row that never landed — and her skip reason said "row 89 was imported"
    about a row that wasn't.  Both Hans vanished, explained by something
    untrue.  A row now claims its phone only once it is known to land.
    """

    def setUp(self):
        self.account = Account.objects.create(name='Shared Phone')

    def _plan(self, csv):
        rows = gi.read_rows('roster.csv', csv.encode())
        parsed, _ = gi.parse_rows(rows)
        return gi.build_plan(self.account, parsed)

    HEADER = "Email,First Name,Last Name,Index,GHIN Id,Phone Number,Gender\n"

    def test_a_skipped_row_does_not_block_its_partner(self):
        plan = self._plan(
            self.HEADER +
            "c@x.com,Charlie,Han,NH,111,510-555-0150,M\n"    # skipped: no index
            "d@x.com,Diana,Han,18.2,222,510-555-0150,F\n"    # must still land
        )
        created = {r.name for r in plan.to_create}
        self.assertEqual(created, {'Diana Han'})
        reasons = {s.row.name: s.code for s in plan.skipped}
        self.assertEqual(reasons, {'Charlie Han': gi.SKIP_NO_INDEX})

    def test_the_winning_line_named_by_a_duplicate_actually_landed(self):
        """The detail must never point at a row that was itself skipped."""
        plan = self._plan(
            self.HEADER +
            "c@x.com,Charlie,Han,NH,111,510-555-0150,M\n"    # skipped
            "d@x.com,Diana,Han,18.2,222,510-555-0150,F\n"    # created
            "e@x.com,Eve,Han,20.0,333,510-555-0150,F\n"      # duplicate of Diana
        )
        dup = [s for s in plan.skipped if s.code == gi.SKIP_DUP_PHONE]
        self.assertEqual(len(dup), 1)
        self.assertEqual(dup[0].row.name, 'Eve Han')
        won = dup[0].detail['won_line']
        diana = next(r for r in plan.to_create if r.name == 'Diana Han')
        self.assertEqual(won, diana.line)          # the row that actually landed
        charlie = next(s.row for s in plan.skipped if s.row.name == 'Charlie Han')
        self.assertNotEqual(won, charlie.line)     # never the skipped one
        landed = {r.line for r in plan.to_create} | {u.row.line for u in plan.to_update} \
            | {r.line for r in plan.unchanged}
        self.assertIn(won, landed)

    def test_a_genuine_duplicate_is_still_skipped(self):
        plan = self._plan(
            self.HEADER +
            "a@x.com,Ann,Bird,10.0,111,510-555-0151,F\n"
            "b@x.com,Bob,Bird,12.0,222,510-555-0151,M\n"     # same phone, lands second
        )
        self.assertEqual([r.name for r in plan.to_create], ['Ann Bird'])
        self.assertEqual([(s.row.name, s.code) for s in plan.skipped],
                         [('Bob Bird', gi.SKIP_DUP_PHONE)])

    def test_a_skipped_row_does_not_block_a_shared_ghin_either(self):
        plan = self._plan(
            self.HEADER +
            "c@x.com,Carl,Gee,NH,4242,,M\n"                  # skipped: no index
            "g@x.com,Gloria,Gee,21.0,4242,,F\n"              # must still land
        )
        self.assertEqual([r.name for r in plan.to_create], ['Gloria Gee'])
