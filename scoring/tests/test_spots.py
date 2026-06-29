"""
scoring/tests/test_spots.py
---------------------------
Spots settlement engine — pay-around (zero-sum within each hole's active
roster), pool split, withdrawal exclusion, and tally upsert/zeroing.
"""

from decimal import Decimal

from django.test import TestCase

from services.spots import setup_spots, tally_spots, spots_summary
from ._helpers import make_tee, make_round, make_foursome


class SpotsEngineTests(TestCase):
    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['nassau', 'spots'])
        self.fs = make_foursome(
            self.round, [('A', 8), ('B', 10), ('C', 12), ('D', 14)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _net(self, summary):
        return {p['name']: p['payout'] for p in summary['players']}

    def test_pay_around_zero_sum(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        tally_spots(self.fs, 1, [{'player_id': self.pid['A'], 'count': 2}])
        tally_spots(self.fs, 2, [{'player_id': self.pid['B'], 'count': 1}])
        s = spots_summary(self.fs)
        net = self._net(s)
        # Hole 1: A=2 → A +6, others −2.  Hole 2: B=1 → B +3, others −1.
        self.assertEqual(net['A'], 5.0)
        self.assertEqual(net['B'], 1.0)
        self.assertEqual(net['C'], -3.0)
        self.assertEqual(net['D'], -3.0)
        self.assertAlmostEqual(sum(net.values()), 0.0)
        self.assertEqual(s['money']['total_spots'], 3)

    def test_pool_split_zero_sum(self):
        setup_spots(self.fs, bet_unit=Decimal('3'), payout_style='pool')
        tally_spots(self.fs, 1, [{'player_id': self.pid['A'], 'count': 2}])
        tally_spots(self.fs, 2, [{'player_id': self.pid['B'], 'count': 1}])
        net = self._net(spots_summary(self.fs))
        # pot = 4×3 = 12, split by spots (A:2, B:1); ante 3 each.
        self.assertEqual(net['A'], 5.0)
        self.assertEqual(net['B'], 1.0)
        self.assertEqual(net['C'], -3.0)
        self.assertEqual(net['D'], -3.0)
        self.assertAlmostEqual(sum(net.values()), 0.0)

    def test_negative_spot_reverses_payment(self):
        # A negative spot = a penalty: the player pays everyone else.
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        tally_spots(self.fs, 1, [{'player_id': self.pid['A'], 'count': -1}])
        net = self._net(spots_summary(self.fs))
        # A −1, n=4: A −3, others +1 each. Zero-sum.
        self.assertEqual(net['A'], -3.0)
        self.assertEqual(net['B'], 1.0)
        self.assertEqual(net['C'], 1.0)
        self.assertEqual(net['D'], 1.0)
        self.assertAlmostEqual(sum(net.values()), 0.0)

    def test_withdrawn_player_excluded_from_hole(self):
        m = self.fs.memberships.get(player_id=self.pid['D'])
        m.withdrew_after_hole = 1
        m.save(update_fields=['withdrew_after_hole'])
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        tally_spots(self.fs, 2, [{'player_id': self.pid['B'], 'count': 1}])
        net = self._net(spots_summary(self.fs))
        # Hole 2 roster = A,B,C (D is out). B +2; A,C −1; D untouched.
        self.assertEqual(net['B'], 2.0)
        self.assertEqual(net['A'], -1.0)
        self.assertEqual(net['C'], -1.0)
        self.assertEqual(net['D'], 0.0)

    def test_tally_zero_deletes_the_row(self):
        setup_spots(self.fs, payout_style='pay_around')
        tally_spots(self.fs, 1, [{'player_id': self.pid['A'], 'count': 2}])
        tally_spots(self.fs, 1, [{'player_id': self.pid['A'], 'count': 0}])
        s = spots_summary(self.fs)
        self.assertEqual(s['money']['total_spots'], 0)
        self.assertTrue(all(p['payout'] == 0.0 for p in s['players']))
