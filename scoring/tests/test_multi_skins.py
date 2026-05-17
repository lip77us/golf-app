"""
scoring/tests/test_multi_skins.py
---------------------------------
Regression tests for services/multi_skins.py — round-level skins pool
that crosses foursomes.

Two-foursome setup so the cross-group score comparison is actually
exercised.  Participant roster is explicit (not the union of every
foursome's roster) — a key difference from single-foursome Skins.
"""
from django.test import TestCase

from services.multi_skins import (
    calculate_multi_skins,
    multi_skins_summary,
    setup_multi_skins,
)

from ._helpers import (
    make_foursome,
    make_round,
    make_tee,
    submit_hole,
)


class MultiSkinsTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross',
                                 net_max_double_bogey=False)
        # Two groups of 4 players each.  Distinct hcps so SO would differ
        # from gross if anyone bothered to compute it.
        self.g1 = make_foursome(
            self.round,
            [('A1', 0), ('A2', 8), ('A3', 12), ('A4', 18)],
            tee=self.tee, group_number=1,
        )
        self.g2 = make_foursome(
            self.round,
            [('B1', 0), ('B2', 6), ('B3', 14), ('B4', 20)],
            tee=self.tee, group_number=2,
        )
        self.pid = {}
        for fs in (self.g1, self.g2):
            for m in fs.memberships.select_related('player'):
                self.pid[m.player.name] = m.player_id

    # ── Cross-foursome winner ──────────────────────────────────────────────

    def test_lowest_score_across_groups_wins_the_skin(self):
        """Group 1 A1 makes birdie; everyone else makes par or worse.
        A1 should take the skin even though B1 is in a different group."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A1'], self.pid['A2'],
                             self.pid['B1'], self.pid['B2']],
            handicap_mode='gross',
        )
        # Hole 1 (par 4): A1 birdie, all others par.
        submit_hole(self.g1, 1, [
            (self.pid['A1'], 3),
            (self.pid['A2'], 4),
            (self.pid['A3'], 4),
            (self.pid['A4'], 4),
        ])
        submit_hole(self.g2, 1, [
            (self.pid['B1'], 4),
            (self.pid['B2'], 4),
            (self.pid['B3'], 4),
            (self.pid['B4'], 4),
        ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        assert totals == {'A1': 1, 'A2': 0, 'B1': 0, 'B2': 0}, totals

    # ── Tie kills the skin ─────────────────────────────────────────────────

    def test_tied_best_score_dies_no_carryover(self):
        """Two participants tie for low → skin dies.  No carryover by
        design — pure design choice baked into the calculator."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A1'], self.pid['B1']],
            handicap_mode='gross',
        )
        # Hole 1: both par.  Tied for low → no winner.
        submit_hole(self.g1, 1, [
            (self.pid['A1'], 4), (self.pid['A2'], 4),
            (self.pid['A3'], 4), (self.pid['A4'], 4),
        ])
        submit_hole(self.g2, 1, [
            (self.pid['B1'], 4), (self.pid['B2'], 4),
            (self.pid['B3'], 4), (self.pid['B4'], 4),
        ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        assert totals == {'A1': 0, 'B1': 0}, totals
        # Hole appears in the summary as a "dead" entry.
        hole_1 = next(h for h in s['holes'] if h['hole'] == 1)
        assert hole_1['winner_id'] is None
        assert hole_1['is_dead']    is True

    # ── Roster opt-in ──────────────────────────────────────────────────────

    def test_non_participants_dont_affect_winners(self):
        """A3 makes the round's lowest score on a hole but isn't in the
        pool.  The skin goes to the lowest *participant* — even if a
        non-participant beat them."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A2'], self.pid['B2']],
            handicap_mode='gross',
        )
        # Hole 1: A3 (NOT in pool) makes eagle; participants make par.
        submit_hole(self.g1, 1, [
            (self.pid['A1'], 4),
            (self.pid['A2'], 4),
            (self.pid['A3'], 2),   # eagle, not a participant
            (self.pid['A4'], 4),
        ])
        submit_hole(self.g2, 1, [
            (self.pid['B1'], 4),
            (self.pid['B2'], 4),
            (self.pid['B3'], 4),
            (self.pid['B4'], 4),
        ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        # A2 and B2 both par → tie → dead skin.  Neither gets a skin.
        assert totals == {'A2': 0, 'B2': 0}, totals

    # ── Net handicap mode ──────────────────────────────────────────────────

    def test_net_mode_uses_each_players_strokes(self):
        """Net mode: A4 (18 hcp) gets a stroke on SI 7 (= hole 1).
        With A4 + A1 + B1 in the pool, all three shooting bogey gross
        on hole 1, A4 nets 4 while A1/B1 net 5 → A4 wins."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A1'], self.pid['A4'],
                             self.pid['B1']],
            handicap_mode='net',
        )
        # Hole 1 (par 4, SI 7).  A4 has 18 strokes → 1 per hole.
        submit_hole(self.g1, 1, [
            (self.pid['A1'], 5),  # bogey, 0 strokes
            (self.pid['A2'], 5),
            (self.pid['A3'], 5),
            (self.pid['A4'], 5),  # bogey, 1 stroke → net 4
        ])
        submit_hole(self.g2, 1, [
            (self.pid['B1'], 5),  # bogey, 0 strokes
            (self.pid['B2'], 5),
            (self.pid['B3'], 5),
            (self.pid['B4'], 5),
        ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        assert totals['A4'] == 1, totals
        assert totals['A1'] == 0, totals
        assert totals['B1'] == 0, totals

    # ── Payouts ────────────────────────────────────────────────────────────

    def test_payout_proportional_to_skins_won(self):
        """Pool = bet_unit × participants.  A1 wins 2 of 3 holes,
        B1 wins 1.  Payouts: A1 = 2/3 × pool, B1 = 1/3 × pool."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A1'], self.pid['B1']],
            handicap_mode='gross',
            bet_unit=10.00,
        )
        # Hole 1 (par 4): A1 birdie, B1 par.   A1 wins.
        # Hole 2 (par 4): A1 par,    B1 birdie. B1 wins.
        # Hole 3 (par 3): A1 par,    B1 bogey. A1 wins.
        for hn, a1, b1 in [(1, 3, 4), (2, 4, 3), (3, 3, 4)]:
            submit_hole(self.g1, hn, [
                (self.pid['A1'], a1), (self.pid['A2'], 4),
                (self.pid['A3'], 4),  (self.pid['A4'], 4),
            ])
            submit_hole(self.g2, hn, [
                (self.pid['B1'], b1), (self.pid['B2'], 4),
                (self.pid['B3'], 4),  (self.pid['B4'], 4),
            ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        assert s['money']['pool']        == 20.0,  s['money']
        assert s['money']['total_skins'] == 3,     s['money']
        payouts = {p['name']: p['payout'] for p in s['players']}
        # A1: 2/3 × 20 = 13.33;  B1: 1/3 × 20 = 6.67
        assert abs(payouts['A1'] - 13.33) < 0.01, payouts
        assert abs(payouts['B1'] -  6.67) < 0.01, payouts
