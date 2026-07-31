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

    # ── Handicap allocation (Strokes-Off) ────────────────────────────────────

    def test_handicap_allocation_surfaced_and_scores(self):
        # Plumbing guard: both allocations set up + summarise, and the chosen
        # allocation is echoed back.  (Per-segment stroke-math mirrors the
        # Sixes allocation, which is covered in test_sixes.)
        for alloc in ('per_segment', 'full_round'):
            setup_rabbit(self.fs, handicap_mode='strokes_off', num_segments=3,
                         handicap_allocation=alloc)
            submit_hole(self.fs, 5, [(self.pid['Ann'], 4), (self.pid['Ben'], 4),
                                     (self.pid['Cal'], 5)])
            calculate_rabbit(self.fs)
            s = rabbit_summary(self.fs)
            assert s['handicap']['allocation'] == alloc, s['handicap']

    def test_setup_defaults_to_per_segment(self):
        g = setup_rabbit(self.fs, handicap_mode='strokes_off', num_segments=3)
        assert g.handicap_allocation == 'per_segment'

    # ── Extra rabbits (accumulate-only, Sixes-style early lock) ───────────────

    def _abc(self):
        return self.pid['Ann'], self.pid['Ben'], self.pid['Cal']

    def test_extra_rabbit_full_leg_after_early_lock(self):
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True,
                     num_segments=3, extra_rabbits=True)
        A, B, C = self._abc()
        # Leg 1 (holes 1-6): Ann wins 1-4 → lead 4 > holes-left → locks at hole 4.
        for h in range(1, 5):
            submit_hole(self.fs, h, [(A, 3), (B, 4), (C, 4)])
        # Leg 2 (holes 5-10): all halved → loose → push.
        for h in range(5, 11):
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4)])
        # Leg 3 (holes 11-16): Ben grabs 11, holds → Ben.
        submit_hole(self.fs, 11, [(A, 4), (B, 3), (C, 4)])
        for h in range(12, 17):
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4)])
        # Extra (holes 17-18): Ann grabs 17, holds → full-value extra (2 holes).
        submit_hole(self.fs, 17, [(A, 3), (B, 4), (C, 4)])
        submit_hole(self.fs, 18, [(A, 4), (B, 4), (C, 4)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        segs = s['segments']
        assert len(segs) == 4, [(x['start_hole'], x['end_hole'], x['is_extra']) for x in segs]
        assert segs[0]['end_hole'] == 4 and segs[0]['holder_short'] == self.sn['Ann']
        assert segs[1]['holder_short'] is None                    # push
        assert segs[2]['holder_short'] == self.sn['Ben']
        ex = segs[3]
        assert ex['is_extra'] and ex['start_hole'] == 17 and ex['end_hole'] == 18
        assert ex['value'] == 6.0 and ex['holder_short'] == self.sn['Ann'], ex
        money = {p['short_name']: p['money'] for p in s['players']}
        assert money[self.sn['Ann']] == 18.0, money
        assert money[self.sn['Ben']] == 0.0, money
        assert money[self.sn['Cal']] == -18.0, money
        assert abs(sum(money.values())) < 1e-9

    def test_single_hole_extra_pays_half(self):
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True,
                     num_segments=3, extra_rabbits=True)
        A, B, C = self._abc()
        # Leg 1 (holes 1-6): halve 1-2 (loose), Ann grabs 3 then wins 4-5.  Lead
        # is 2 with 2 to play at hole 4 (2 > 2 is false → no lock) and 3 with 1
        # to play at hole 5 (3 > 1 → locks) — a five-hole leg.
        for h in (1, 2):
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4)])
        for h in (3, 4, 5):
            submit_hole(self.fs, h, [(A, 3), (B, 4), (C, 4)])
        # Legs 2 & 3 (holes 6-11, 12-17): all halved → push.
        for h in range(6, 18):
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4)])
        # Extra = hole 18 only → HALF value.
        submit_hole(self.fs, 18, [(A, 3), (B, 4), (C, 4)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        ex = s['segments'][-1]
        assert ex['is_extra'] and ex['holes'] == 1
        assert ex['start_hole'] == 18 and ex['end_hole'] == 18
        assert ex['value'] == 3.0, ex          # half of bet_unit 6
        assert ex['holder_short'] == self.sn['Ann'] and ex['payout'] == 6.0, ex
        money = {p['short_name']: p['money'] for p in s['players']}
        # Leg1 Ann +12 ; extra (half) Ann +6 → +18 ; Ben −6−3 ; Cal −6−3.
        assert money[self.sn['Ann']] == 18.0, money
        assert money[self.sn['Ben']] == -9.0, money
        assert money[self.sn['Cal']] == -9.0, money
        assert abs(sum(money.values())) < 1e-9

    def test_extra_rabbits_forced_off_in_stop_mode(self):
        g = setup_rabbit(self.fs, handicap_mode='gross', accumulate=False,
                         num_segments=3, extra_rabbits=True)
        assert g.extra_rabbits is False           # accumulate-only
        for h in range(1, 19):
            submit_hole(self.fs, h, [(self.pid['Ann'], 3),
                                     (self.pid['Ben'], 4), (self.pid['Cal'], 4)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        assert len(s['segments']) == 3
        assert all(not x['is_extra'] for x in s['segments'])

    def test_extra_on_but_no_early_lock_stays_three_legs(self):
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True,
                     num_segments=3, extra_rabbits=True)
        A, B, C = self._abc()
        submit_hole(self.fs, 1, [(A, 3), (B, 4), (C, 4)])     # Ann grabs
        for h in range(2, 7):
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4)])  # halves → lead 1
        submit_hole(self.fs, 7, [(A, 4), (B, 3), (C, 4)])     # Ben grabs
        for h in range(8, 13):
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4)])
        submit_hole(self.fs, 13, [(A, 4), (B, 4), (C, 3)])    # Cal grabs
        for h in range(14, 19):
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)
        assert len(s['segments']) == 3
        assert all(not x['is_extra'] for x in s['segments'])
        holders = [x['holder_short'] for x in s['segments']]
        assert holders == [self.sn['Ann'], self.sn['Ben'], self.sn['Cal']], holders

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

    def test_back_nine_three_segments_split_by_position(self):
        # Back 9 (holes 10-18) with 3 segments → three 3-hole segments in play
        # order: [10,11,12], [13,14,15], [16,17,18]. Ann wins every hole → holds
        # the rabbit through all three segments.
        self.round.num_holes = 9
        self.round.starting_hole = 10
        self.round.save(update_fields=['num_holes', 'starting_hole'])
        setup_rabbit(self.fs, handicap_mode='gross', accumulate=True,
                     num_segments=3)
        for h in range(10, 19):
            submit_hole(self.fs, h, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                      (self.pid['Cal'], 4)])
        calculate_rabbit(self.fs)
        s = rabbit_summary(self.fs)

        # Segments are the three played 3-hole runs, not 1-6/7-12/13-18.
        segs = {x['index']: (x['start_hole'], x['end_hole']) for x in s['segments']}
        assert segs == {1: (10, 12), 2: (13, 15), 3: (16, 18)}, segs
        # Only the 9 played holes appear, in play order.
        assert [h['hole'] for h in s['holes']] == list(range(10, 19))
        # Round completes on 9 holes (not stuck waiting for 18).
        assert s['status'] == 'complete', s['status']
        # Ann sweeps all three segments: +12 each × 3 = +36; Ben/Cal −18 each.
        money = {p['short_name']: p['money'] for p in s['players']}
        assert money[self.sn['Ann']] == 36.0, money
        assert money[self.sn['Ben']] == -18.0, money
        assert money[self.sn['Cal']] == -18.0, money
        assert abs(sum(money.values())) < 1e-9
