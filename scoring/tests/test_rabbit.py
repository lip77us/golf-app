"""
scoring/tests/test_rabbit.py
----------------------------
Regression tests for services/rabbit.py — catch/hold/free transitions,
the accumulate lead buffer vs stop-on-first-loss, ties as no-ops,
segment payouts (push when loose), and the zero-sum invariant.

Gross mode keeps the score math obvious.
"""
from django.test import TestCase

from services.rabbit import calculate_rabbit, setup_rabbit, rabbit_summary

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class RabbitTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = 6
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 0), ('Cal', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        # The test factory derives short_name from the name; use the real
        # value so assertions don't depend on that derivation.
        self.sn = {m.player.name: m.player.short_name
                   for m in self.fs.memberships.select_related('player')}

    def _holder(self, summary, hole):
        h = next(x for x in summary['holes'] if x['hole'] == hole)
        return h['holder_short'], h['lead'], h['event']

    # ── Catch / hold / free ──────────────────────────────────────────────────

    def test_first_outright_win_catches_rabbit(self):
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True)
        # Hole 1: tie (nobody catches).  Hole 2: Ann wins outright → catches.
        submit_hole(self.fs, 1, [(self.pid['Ann'], 4), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])
        submit_hole(self.fs, 2, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        assert self._holder(s, 1) == (None, 0, 'tie'), self._holder(s, 1)
        assert self._holder(s, 2) == (self.sn['Ann'], 1, 'grab'), self._holder(s, 2)

    def test_accumulate_builds_and_erodes_lead(self):
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True)
        # 1: Ann catches (+1).  2: Ann wins again (+2).  3: Ben beats Ann (+1).
        # 4: Ben beats Ann again → lead 0 → freed.
        submit_hole(self.fs, 1, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])
        submit_hole(self.fs, 2, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])
        submit_hole(self.fs, 3, [(self.pid['Ann'], 5), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 5)])
        submit_hole(self.fs, 4, [(self.pid['Ann'], 5), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 5)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        assert self._holder(s, 1) == (self.sn['Ann'], 1, 'grab')
        assert self._holder(s, 2) == (self.sn['Ann'], 2, 'extend')
        assert self._holder(s, 3) == (self.sn['Ann'], 1, 'beaten')
        assert self._holder(s, 4) == (None, 0, 'freed')

    def test_stop_mode_frees_on_first_loss(self):
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=False)
        # 1: Ann catches.  2: Ann wins (stop → stays at lead 1, 'held').
        # 3: Ben beats Ann → freed immediately.
        submit_hole(self.fs, 1, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])
        submit_hole(self.fs, 2, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])
        submit_hole(self.fs, 3, [(self.pid['Ann'], 5), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 5)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        assert self._holder(s, 2) == (self.sn['Ann'], 1, 'held')
        assert self._holder(s, 3) == (None, 0, 'freed')

    def test_tie_does_not_change_holder(self):
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True)
        submit_hole(self.fs, 1, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])
        # 2: Ann ties Ben for low (no opponent strictly lower) → held, no change.
        submit_hole(self.fs, 2, [(self.pid['Ann'], 4), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 5)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        assert self._holder(s, 2) == (self.sn['Ann'], 1, 'held'), self._holder(s, 2)

    # ── Segments + money ─────────────────────────────────────────────────────

    def test_three_segments_per_match_stake_and_push_when_loose(self):
        # Sixes-style: each segment stakes the FULL bet_unit (6), not a share
        # of one pot.  Per won segment a loser pays 6 and the holder collects
        # from both (+12 net per won segment).
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True,
                     num_segments=3)
        # Segment 1 (1-6): Ann catches hole 1 and holds (wins all) → Ann.
        for h in range(1, 7):
            submit_hole(self.fs, h, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                      (self.pid['Cal'], 4)])
        # Segment 2 (7-12): all ties → never caught → loose → push.
        for h in range(7, 13):
            submit_hole(self.fs, h, [(self.pid['Ann'], 4), (self.pid['Ben'], 4),
                                      (self.pid['Cal'], 4)])
        # Segment 3 (13-18): Ben catches hole 13 and holds → Ben.
        for h in range(13, 19):
            submit_hole(self.fs, h, [(self.pid['Ann'], 4), (self.pid['Ben'], 3),
                                      (self.pid['Cal'], 4)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        segs = {x['index']: x for x in s['segments']}
        assert segs[1]['holder_short'] == self.sn['Ann'] and segs[1]['payout'] == 12.0
        assert segs[2]['holder_short'] is None and segs[2]['payout'] == 0.0  # push
        assert segs[3]['holder_short'] == self.sn['Ben'] and segs[3]['payout'] == 12.0
        money = {p['short_name']: p['money'] for p in s['players']}
        # Ann: +12 (seg1) −6 (seg3) = +6 ; Ben: −6 (seg1) +12 (seg3) = +6 ;
        # Cal: −6 (seg1) −6 (seg3) = −12.  Segment 2 pushes.
        assert money[self.sn['Ann']] == 6.0, money
        assert money[self.sn['Ben']] == 6.0, money
        assert money[self.sn['Cal']] == -12.0, money
        assert abs(sum(money.values())) < 1e-9

    def test_single_segment_winner_takes_whole_pot(self):
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True,
                     num_segments=1)
        for h in range(1, 19):
            submit_hole(self.fs, h, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                      (self.pid['Cal'], 4)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        money = {p['short_name']: p['money'] for p in s['players']}
        # 1 segment, stake 6.  Ann wins it: +12 net (6 from each), Ben/Cal −6.
        assert money == {self.sn['Ann']: 12.0, self.sn['Ben']: -6.0, self.sn['Cal']: -6.0}, money
        # pot = max a player can lose = stake × segments = 6 × 1.
        assert s['money']['pot'] == 6.0, s['money']
