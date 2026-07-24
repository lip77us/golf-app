"""
api/test_low_net_modes.py
-------------------------
12A phase 1 — the Stroke Play leaderboard payload now carries all three display
modes (Gross / Net / Strokes-off), each independently ranked, so the client can
re-rank the selector without refetching.
See docs/features/12a-scorecard-display-modes.md.

Scenario is built so Gross and Net rankings FLIP:
  Ann  — handicap 0,  pars every hole            -> gross 72 (E),  net 72 (E)
  Bea  — handicap 18, 16 bogeys + 2 pars         -> gross 88 (+16), net 70 (-2)
So Ann leads Gross, Bea leads Net — proving the modes rank independently.
"""
from django.test import TestCase

from games.models import LowNetRoundConfig
from services.low_net_round import low_net_round_summary
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)


class LowNetModesTests(TestCase):
    def setUp(self):
        course = make_course()
        self.tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.round = make_round(course=course, handicap_mode='net',
                                net_percent=100, active_games=['low_net_round'])
        self.fs = make_foursome(self.round, [('Ann', 0), ('Bea', 18)], tee=self.tee)
        # Configured mode = net, with a single first-place payout.
        LowNetRoundConfig.objects.create(
            round=self.round, handicap_mode='net', net_percent=100,
            payouts=[{'place': 1, 'amount': 20}],
        )
        self.par = {h['number']: h['par'] for h in DEFAULT_HOLES}
        # Ann pars everything; Bea pars holes 1-2 and bogeys 3-18.
        for h in range(1, 19):
            ann = self.par[h]
            bea = self.par[h] + (0 if h <= 2 else 1)
            submit_hole(self.fs, h, [(self._pid('Ann'), ann), (self._pid('Bea'), bea)])

    def _pid(self, name):
        return next(m.player_id for m in self.fs.memberships.all()
                    if m.player.name == name)

    @staticmethod
    def _by_name(results):
        return {r['name']: r for r in results}

    # ── structure ────────────────────────────────────────────────────────────
    def test_all_three_modes_present(self):
        s = low_net_round_summary(self.round)
        self.assertIn('modes', s)
        self.assertEqual(set(s['modes']), {'gross', 'net', 'strokes_off'})
        for m in s['modes'].values():
            self.assertTrue(m['results'])            # non-empty
        self.assertEqual(s['primary_mode'], 'net')

    def test_results_mirror_primary_mode(self):
        """Backward-compat: top-level `results` is exactly the configured mode."""
        s = low_net_round_summary(self.round)
        self.assertEqual(s['results'], s['modes'][s['primary_mode']]['results'])

    # ── scoring correctness ───────────────────────────────────────────────────
    def test_gross_totals_are_raw(self):
        s = low_net_round_summary(self.round)
        g = self._by_name(s['modes']['gross']['results'])
        self.assertEqual(g['Ann']['total_net'], 72)   # 'total_net' holds the mode total
        self.assertEqual(g['Bea']['total_net'], 88)

    def test_net_improves_high_handicapper(self):
        s = low_net_round_summary(self.round)
        n = self._by_name(s['modes']['net']['results'])
        self.assertEqual(n['Bea']['total_net'], 70)
        self.assertEqual(n['Bea']['net_to_par'], -2)
        self.assertEqual(n['Ann']['net_to_par'], 0)

    def test_gross_and_net_rank_independently(self):
        """The whole point of 12A: switching mode re-ranks the field."""
        s = low_net_round_summary(self.round)
        gross_leader = s['modes']['gross']['results'][0]['name']
        net_leader   = s['modes']['net']['results'][0]['name']
        self.assertEqual(gross_leader, 'Ann')
        self.assertEqual(net_leader, 'Bea')

    def test_strokes_off_relative_to_low(self):
        s = low_net_round_summary(self.round)
        so = self._by_name(s['modes']['strokes_off']['results'])
        # Low handicapper (Ann, 0) gets nothing; Bea gets 18 − 0 = 18.
        self.assertEqual(so['Ann']['total_strokes'], 0)
        self.assertEqual(so['Bea']['total_strokes'], 18)

    # ── payouts belong only to the configured mode ────────────────────────────
    def test_only_primary_mode_carries_payouts(self):
        s = low_net_round_summary(self.round)
        # Net is primary: its rank-1 (Bea) wins the $20.
        net = self._by_name(s['modes']['net']['results'])
        self.assertEqual(net['Bea']['payout'], 20.0)
        self.assertIsNone(net['Ann']['payout'])
        # Display-only modes carry no money.
        for key in ('gross', 'strokes_off'):
            for r in s['modes'][key]['results']:
                self.assertIsNone(r['payout'], f'{key} should have no payouts')
