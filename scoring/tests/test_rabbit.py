"""
scoring/tests/test_rabbit.py
----------------------------
Regression tests for services/rabbit.py — catch/hold/free transitions,
the accumulate lead buffer vs stop-on-first-loss, ties as no-ops,
segment payouts (push when loose), and the zero-sum invariant.

Gross mode keeps the score math obvious.
"""
from django.test import TestCase

from services.rabbit import (calculate_rabbit, rabbit_hole_card,
                             rabbit_summary, setup_rabbit)

from ._helpers import (DEFAULT_HOLES, make_foursome, make_round, make_tee,
                       submit_hole)


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

    def test_setup_defaults_to_straight_up(self):
        """**Round-wide stroke index by default** (22 Sep 2026), matching
        Sixes, which moved on 17 Sep.

        Spreading a golfer's strokes across the legs allocates them to each
        leg's OWN hardest holes, so the same handicap lands on different holes
        depending on how the round is cut. Round-wide is the answer he can
        check against his card. `per_segment` is still offered and still
        scored; it is no longer what a TD gets without asking.
        """
        g = setup_rabbit(self.fs, handicap_mode='strokes_off', num_segments=3)
        assert g.handicap_allocation == 'full_round'

    def _cal_so9(self):
        """Foursome where Cal gets SO=9 — splits 3·3·3 across the three 6-hole
        legs, but a FULL-ROUND spread over the test tee is 4·3·2 (last leg
        shorted a stroke).  Returns (fs, pid)."""
        rnd = make_round(self.tee.course)
        rnd.bet_unit = 6
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('Ann', 0), ('Ben', 0), ('Cal', 9)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        return fs, pid

    def _cal_seg_strokes(self, summary, pid):
        def cal(hole):
            h = next(x for x in summary['holes'] if x['hole'] == hole)
            e = next(x for x in h['entries'] if x['player_id'] == pid['Cal'])
            return e['strokes']
        return [sum(cal(h) for h in seg)
                for seg in (range(1, 7), range(7, 13), range(13, 19))]

    def test_per_segment_strokes_stable_on_unscored_holes(self):
        # Regression: the play-screen / "Rabbit by hole" stroke dots estimated a
        # FULL-ROUND spread on UNSCORED holes and only switched to the
        # per-segment truth once a hole was scored — so a segmented
        # strokes-off game's dots visibly moved mid-round, and the last leg read
        # 2 strokes instead of 3.  The summary must report the per-segment
        # allocation (3·3·3) on every hole up front, scored or not.
        fs, pid = self._cal_so9()
        setup_rabbit(fs, handicap_mode='strokes_off', num_segments=3,
                     handicap_allocation='per_segment')
        # Only hole 1 is scored — the last two legs are untouched.
        submit_hole(fs, 1, [(pid['Ann'], 4), (pid['Ben'], 4), (pid['Cal'], 5)])
        calculate_rabbit(fs)
        s = rabbit_summary(fs)
        assert self._cal_seg_strokes(s, pid) == [3, 3, 3], \
            self._cal_seg_strokes(s, pid)

    def test_strokes_field_matches_gross_minus_net_on_scored_holes(self):
        # The advertised allocation must equal what the engine actually scored,
        # so the display value and the settlement can't drift.
        fs, pid = self._cal_so9()
        setup_rabbit(fs, handicap_mode='strokes_off', num_segments=3,
                     handicap_allocation='per_segment')
        for h in range(1, 19):
            submit_hole(fs, h, [(pid['Ann'], 4), (pid['Ben'], 4),
                                (pid['Cal'], 5)])
        calculate_rabbit(fs)
        s = rabbit_summary(fs)
        for h in s['holes']:
            for e in h['entries']:
                if e['gross'] is not None and e['net_score'] is not None:
                    assert e['strokes'] == e['gross'] - e['net_score'], \
                        (h['hole'], e)
        assert self._cal_seg_strokes(s, pid) == [3, 3, 3]

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

    def test_early_locks_do_not_move_strokes(self):
        # Strokes-Off + per-segment + extras: each leg spreads its share over its
        # whole WINDOW, and an early lock hands the unplayed tail (and its
        # strokes) to the next leg, which allocates its own.  Played holes are
        # therefore never touched.  Same rule Sixes uses — this scenario produces
        # the identical allocation there.
        rnd = make_round(self.tee.course)
        rnd.bet_unit = 6
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd,
            [('Ann', 0), ('Ben', 0), ('Cal', 9)],   # Cal gets 9 strokes-off
            tee=self.tee,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        A, B, C = pid['Ann'], pid['Ben'], pid['Cal']
        setup_rabbit(fs, handicap_mode='strokes_off', accumulate=True,
                     num_segments=3, extra_rabbits=True,
                     handicap_allocation='per_segment')
        # Ann laps the field on every hole, so each leg locks at its 4th hole:
        # legs 1-4, 5-8, 9-12, then extra 13-16 (locks) and extra 17-18.
        for h in range(1, 19):
            submit_hole(fs, h, [(A, 3), (B, 6), (C, 6)])
        calculate_rabbit(fs)
        s = rabbit_summary(fs)

        segs = [(x['start_hole'], x['end_hole'], x['is_extra']) for x in s['segments']]
        assert segs == [(1, 4, False), (5, 8, False), (9, 12, False),
                        (13, 16, True), (17, 18, True)], segs

        def net(hole, player_id):
            h = next(x for x in s['holes'] if x['hole'] == hole)
            return next(e['net_score'] for e in h['entries']
                        if e['player_id'] == player_id)

        # Cal's 9 strokes-off split 3·3·3, each leg over its own window:
        #   leg 1 window 1-6  → 5/2/1, locks on 4 → hole 5 handed on   → 1, 2
        #   leg 2 window 5-10 → 5/9/10, locks on 8 → 9, 10 handed on   → 5
        #   leg 3 window 9-14 → 14/11/9, locks on 12 → 13, 14 handed on→ 9, 11
        #   extra 13-18 (full-round SI<=9) → 14/18, locks on 16        → 14
        #   extra 17-18 (full-round)                                   → 18
        def strokes(hole, player_id):
            h = next(x for x in s['holes'] if x['hole'] == hole)
            return next(e['strokes'] for e in h['entries']
                        if e['player_id'] == player_id)
        assert [h for h in range(1, 19) if strokes(h, C)] == \
            [1, 2, 5, 9, 11, 14, 18], \
            [h for h in range(1, 19) if strokes(h, C)]

        # A leg's own closeout never shortens its allocation window, so holes it
        # DID play keep what they were issued: hole 3/4 got no stroke from leg 1
        # (window 1-6 put them on 5/2/1) and still don't.
        assert net(3, C) == 6 and net(4, C) == 6, s['holes']

        # The advertised per-hole `strokes` still tracks what the engine scored.
        for h in s['holes']:
            for e in h['entries']:
                if e['gross'] is not None and e['net_score'] is not None:
                    assert e['strokes'] == e['gross'] - e['net_score'], \
                        (h['hole'], e)

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

    # ── Stroke allocation must never move onto a played hole ──────────────────

    def _hardest_12_tee(self):
        """Test tee where hole 12 is the HARDEST hole on the course (SI 1) —
        swaps the default stroke indexes of holes 5 and 12."""
        holes = [dict(h) for h in DEFAULT_HOLES]
        si = {5: 16, 12: 1}
        for h in holes:
            if h['number'] in si:
                h['stroke_index'] = si[h['number']]
        return make_tee(self.tee.course, tee_name='Blue', holes=holes)

    def _glenn_strokes(self, summary, pid):
        """{hole: strokes} for the stroke-receiving player."""
        out = {}
        for h in summary['holes']:
            e = next(x for x in h['entries'] if x['player_id'] == pid)
            out[h['hole']] = e['strokes']
        return out

    def test_stroke_hole_handed_to_the_next_leg(self):
        # Reported from a real round, then pinned to the exact case that matters:
        # hole 12 is the hardest on the course, so Glenn's 4 strokes split 2/1/1
        # over the sixes as holes 1 + 2, hole 12, hole 14.  Leg 2 locks at hole
        # 11, handing hole 12 to leg 3 (window 12-17).
        #
        #   * hole 11 — already played — must NOT gain a stroke (the bug), and
        #   * leg 3 must put its stroke on hole 12, the hardest hole of its own
        #     window, and NOT on 13-17.
        tee = self._hardest_12_tee()
        rnd = make_round(tee.course)
        rnd.bet_unit = 6
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('Ann', 0), ('Ben', 0), ('Glenn', 4)], tee=tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        A, B, G = pid['Ann'], pid['Ben'], pid['Glenn']

        setup_rabbit(fs, handicap_mode='strokes_off', num_segments=3,
                     handicap_allocation='per_segment',
                     accumulate=True, extra_rabbits=True)

        # Before a ball is struck: 2 on the first six, 1 on the second, 1 on the
        # third — holes 1 + 2, hole 12, hole 14.
        calculate_rabbit(fs)
        before = self._glenn_strokes(rabbit_summary(fs), G)
        assert [h for h, s in before.items() if s] == [1, 2, 12, 14], before

        # Leg 1 is halved (every hole tied), so it runs its full six.  Ann then
        # grabs the rabbit on 7 and wins 11 → lead 2 with one hole left in the
        # leg, so leg 2 locks on hole 11.
        for h in (1, 2):
            submit_hole(fs, h, [(A, 4), (B, 4), (G, 5)])   # Glenn strokes → tied
        for h in (3, 4, 5, 6):
            submit_hole(fs, h, [(A, 4), (B, 4), (G, 4)])
        submit_hole(fs, 7, [(A, 3), (B, 4), (G, 4)])
        for h in (8, 9, 10):
            submit_hole(fs, h, [(A, 4), (B, 4), (G, 4)])
        submit_hole(fs, 11, [(A, 3), (B, 4), (G, 4)])
        calculate_rabbit(fs)
        s = rabbit_summary(fs)

        # Leg 2 locked on 11; leg 3 runs 12-17.
        segs = [(x['start_hole'], x['end_hole']) for x in s['segments']]
        assert segs[1] == (7, 11) and segs[2] == (12, 17), segs

        after = self._glenn_strokes(s, G)
        # Nothing appeared on a played hole — hole 11 above all.
        for h in range(1, 12):
            assert after[h] == before[h], (h, before[h], after[h])
        assert after[11] == 0, after
        # Leg 3 puts its stroke on hole 12 (hardest of ITS window) and nowhere
        # else; leg 2's stroke there was handed on, so hole 12 carries exactly 1.
        assert after[12] == 1, after
        assert all(after[h] == 0 for h in range(13, 19)), after

    def test_no_played_hole_ever_changes_strokes(self):
        # The invariant behind all of the above, checked hole by hole across a
        # whole round with three early locks and two extras: once a hole has
        # been played, the strokes it carries are final.
        tee = self._hardest_12_tee()
        rnd = make_round(tee.course)
        rnd.bet_unit = 6
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('Ann', 0), ('Ben', 0), ('Glenn', 9)], tee=tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        A, B, G = pid['Ann'], pid['Ben'], pid['Glenn']
        setup_rabbit(fs, handicap_mode='strokes_off', num_segments=3,
                     handicap_allocation='per_segment',
                     accumulate=True, extra_rabbits=True)

        played: dict = {}
        for hole in range(1, 19):
            calculate_rabbit(fs)
            now = self._glenn_strokes(rabbit_summary(fs), G)
            for h, s in played.items():
                assert now[h] == s, \
                    f'hole {h} strokes moved {s} → {now[h]} before hole {hole}'
            played[hole] = now[hole]
            # Ann laps the field, so every leg locks as early as it can.
            submit_hole(fs, hole, [(A, 3), (B, 6), (G, 6)])
        calculate_rabbit(fs)
        final = self._glenn_strokes(rabbit_summary(fs), G)
        for h, s in played.items():
            assert final[h] == s, (h, s, final[h])

    def _decided_probe(self, extras):
        """Leg 2 clinched on hole 11 (lead 2, one hole left).  Returns the
        summary's segment rows."""
        rnd = make_round(self.tee.course)
        rnd.bet_unit = 6
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        A, B, C = pid['Ann'], pid['Ben'], pid['Cal']
        setup_rabbit(fs, handicap_mode='gross', num_segments=3,
                     accumulate=True, extra_rabbits=extras)
        for h in range(1, 7):
            submit_hole(fs, h, [(A, 4), (B, 4), (C, 4)])
        submit_hole(fs, 7, [(A, 3), (B, 4), (C, 4)])       # Ann grabs
        for h in (8, 9, 10):
            submit_hole(fs, h, [(A, 4), (B, 4), (C, 4)])
        submit_hole(fs, 11, [(A, 3), (B, 4), (C, 4)])      # lead 2, 1 to play
        calculate_rabbit(fs)
        return rabbit_summary(fs)['segments']

    def test_leg_decided_early_is_flagged_without_extras(self):
        # Extra rabbits OFF: the leg still PLAYS its full 7-12 range (hole 12
        # counts for nothing), so the range alone can't say the rabbit is
        # already won.  decided_on names the hole it was settled on.
        segs = self._decided_probe(extras=False)
        assert (segs[1]['start_hole'], segs[1]['end_hole']) == (7, 12), segs
        assert segs[1]['decided_on'] == 11, segs[1]
        # Legs still running are not "decided".
        assert segs[2]['decided_on'] is None, segs[2]

    def test_leg_decided_early_matches_the_lock_with_extras(self):
        # Extra rabbits ON: the leg ENDS where it was decided, so the two agree.
        segs = self._decided_probe(extras=True)
        assert segs[1]['end_hole'] == 11 and segs[1]['decided_on'] == 11, segs[1]

    def test_summary_emits_a_scorecard_block(self):
        # The leaderboard card renders the shared grid widget, which needs the
        # Wolf/Sixes-shaped scorecard block: per-hole gross + strokes per player,
        # plus winner_id so the hole winner's cell is tinted.
        rnd = make_round(self.tee.course)
        rnd.bet_unit = 6
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('Ann', 0), ('Ben', 0), ('Cal', 4)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        A, B, C = pid['Ann'], pid['Ben'], pid['Cal']
        setup_rabbit(fs, handicap_mode='strokes_off', num_segments=3)
        submit_hole(fs, 5, [(A, 3), (B, 4), (C, 5)])
        calculate_rabbit(fs)
        sc = rabbit_summary(fs)['scorecard']
        assert [p['player_id'] for p in sc['players']] == [A, B, C], sc['players']
        assert sc['holes_in_play'] == list(range(1, 19)), sc['holes_in_play']
        h5 = next(h for h in sc['holes'] if h['hole'] == 5)
        assert h5['winner_id'] == A, h5
        assert h5['stroke_index'] == 1 and h5['par'] == 4, h5
        by_pid = {s['player_id']: s for s in h5['scores']}
        assert by_pid[A]['gross'] == 3 and by_pid[C]['gross'] == 5, h5
        assert by_pid[C]['strokes'] == 1, h5      # hardest hole of the first six


class SettingsChipsTests(TestCase):
    """The board's settings strip, in the server's words.

    *"Rabbit has lots of options not listed in the leaderboard bubbles"*
    (Paul, 30 Oct 2026) — the strip has to carry every setting a group chose,
    and a switch appears only when it is ON.
    """

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['rabbit'])
        self.fs = make_foursome(
            self.round, [('A', 8), ('B', 12), ('C', 16)], tee=self.tee)

    def _chips(self, **kw):
        setup_rabbit(self.fs, **kw)
        return rabbit_summary(self.fs)['settings']

    def test_it_names_the_handicap_and_how_a_rabbit_is_caught(self):
        chips = self._chips(handicap_mode='net', net_percent=90,
                            accumulate=True, num_segments=3)
        self.assertIn('Net 90%', chips)
        self.assertIn('Accumulate', chips)

    def test_stop_after_one_is_named_as_itself(self):
        self.assertIn('Stop after one',
                      self._chips(accumulate=False, num_segments=3))

    def test_the_split_is_stated_as_n_by_holes(self):
        self.assertIn('3 × 6', self._chips(num_segments=3))
        self.assertIn('2 × 9', self._chips(num_segments=2))
        self.assertIn('1 × 18', self._chips(num_segments=1))

    def test_a_switch_that_is_OFF_is_not_claimed(self):
        """A group playing without carry or without rolls-on has not chosen
        anything to report — and both default off."""
        for kw in ({'accumulate': True}, {'accumulate': False}):
            joined = ' '.join(self._chips(num_segments=3, **kw)).lower()
            self.assertNotIn('carry', joined)
            self.assertNotIn('roll', joined)

    def test_rolling_on_is_named_for_the_RULE(self):
        """It was `Extra rabbits` — named for the by-product. The extra
        rabbit is what falls out of rolling on, not the thing anybody
        chose."""
        on = self._chips(num_segments=3, extra_rabbits=True)
        self.assertIn('Rolls on', on)
        self.assertNotIn('Extra rabbits', on)
        self.assertNotIn('Rolls on', self._chips(num_segments=3,
                                                 extra_rabbits=False))

    def test_carry_is_named_when_it_is_on(self):
        self.assertIn('Carry', self._chips(num_segments=3, carry=True))

    def test_where_the_strokes_FALL_is_a_choice_and_it_is_named(self):
        """The guide calls it "a genuine choice, not a technicality":
        spreading a seven-handicapper's strokes across the three rabbits
        rather than onto the course's hardest holes is what keeps every
        rabbit contested. It was missing from the strip entirely."""
        self.assertIn('Strokes per rabbit',
                      self._chips(num_segments=3, handicap_mode='net',
                                  handicap_allocation='per_segment'))
        self.assertIn('Strokes over the round',
                      self._chips(num_segments=3, handicap_mode='net',
                                  handicap_allocation='full_round'))

    def test_a_gross_game_has_no_allocation_to_report(self):
        # No strokes, so where they fall describes a choice with no effect.
        joined = ' '.join(self._chips(num_segments=3, handicap_mode='gross'))
        self.assertNotIn('Strokes per rabbit', joined)
        self.assertNotIn('Strokes over the round', joined)

    def test_the_stake_is_named_because_this_game_s_unit_is_plain(self):
        self.round.bet_unit = 5
        self.round.save(update_fields=['bet_unit'])
        self.assertIn('$5 a rabbit', self._chips(num_segments=3))


class CarryTests(TestCase):
    """A loose rabbit rolls its stake into the next one.

    Asked for by Paul on 28 Oct 2026, *"defaulting to no"* — it changes what
    every later rabbit is worth, so a group opts into it.

    Carry is SETTLEMENT only: who holds a rabbit and when it is decided are
    untouched, which is what keeps the change small and what lets these
    tests flip the switch on one scored round and compare.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = 5
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _play(self, winners):
        """`winners` maps hole -> the name who wins it outright, or None for
        a halved hole."""
        for hole in range(1, 19):
            w = winners.get(hole)
            submit_hole(self.fs, hole, [
                (self.pid[n], 4 if n == w else (4 if w is None else 5))
                for n in ('Ann', 'Ben', 'Cal')
            ])
        calculate_rabbit(self.fs)

    def _summary(self, carry):
        g = self.fs.rabbit_game
        g.carry = carry
        g.save(update_fields=['carry'])
        return rabbit_summary(self.fs)

    def _legs(self, s):
        return [(x['value'], x['carried_in'], x['payout'])
                for x in s['segments']]

    def _money(self, s):
        return {p['short_name']: p['money'] for p in s['players']}

    def test_it_is_OFF_by_default(self):
        setup_rabbit(self.fs, num_segments=3)
        self.assertFalse(self.fs.rabbit_game.carry)
        # And an unset kwarg keeps a round playing what it was playing.
        setup_rabbit(self.fs, num_segments=3, accumulate=False)
        self.assertFalse(self.fs.rabbit_game.carry)

    def test_a_loose_rabbit_rolls_its_stake_into_the_next(self):
        # R1 (1-6) halved throughout -> loose. R2 (7-12) to Ann.
        setup_rabbit(self.fs, num_segments=3, accumulate=False)
        self._play({7: 'Ann', 13: 'Ben'})

        off = self._summary(False)
        self.assertEqual(self._legs(off)[0], (5.0, 0.0, 0.0),
                         'without carry a loose rabbit pays nothing')
        self.assertEqual(self._legs(off)[1][0], 5.0)

        on = self._summary(True)
        self.assertEqual(self._legs(on)[0], (5.0, 0.0, 0.0),
                         'the loose rabbit still pays nobody')
        value, carried, payout = self._legs(on)[1]
        self.assertEqual((value, carried), (10.0, 5.0),
                         'R1s stake rides on R2')
        self.assertEqual(payout, 20.0, 'two opponents at $10')

    def test_carries_ACCUMULATE_across_consecutive_loose_rabbits(self):
        # R1 and R2 both loose; R3 takes all three stakes.
        setup_rabbit(self.fs, num_segments=3, accumulate=False)
        self._play({13: 'Ann'})
        legs = self._legs(self._summary(True))
        # `value` is the leg's own stake PLUS what rolled in, so it grows.
        self.assertEqual(legs[0][:2], (5.0, 0.0))
        self.assertEqual(legs[1][:2], (10.0, 5.0))
        self.assertEqual(legs[2][:2], (15.0, 10.0))
        # Ann takes all three stakes from two opponents.
        self.assertEqual(legs[2][2], 30.0)

    def test_a_loose_LAST_rabbit_is_won_by_nobody(self):
        """There is nothing to carry into, so that stake is never won.

        It falls out of the walk rather than being special-cased.
        """
        setup_rabbit(self.fs, num_segments=3, accumulate=False)
        self._play({1: 'Ann', 7: 'Ben'})
        on = self._summary(True)
        self.assertEqual(self._legs(on)[2], (5.0, 0.0, 0.0))
        # ...and the money is the same as with carry off, because no carry
        # ever reached anybody.
        self.assertEqual(self._money(on), self._money(self._summary(False)))

    def test_it_stays_zero_sum(self):
        setup_rabbit(self.fs, num_segments=3, accumulate=False)
        self._play({7: 'Ann', 13: 'Ben'})
        for carry in (False, True):
            money = self._money(self._summary(carry))
            self.assertAlmostEqual(sum(money.values()), 0.0, places=2,
                                   msg=f'carry={carry}')

    def test_the_total_at_risk_does_not_change(self):
        """A carry MOVES a stake; it does not add one.

        `max_liability` counts each leg's own stake once, so a group cannot
        be told it is playing for more than it put up.
        """
        setup_rabbit(self.fs, num_segments=3, accumulate=False)
        self._play({7: 'Ann'})
        self.assertEqual(self._summary(True)['money']['max_liability'],
                         self._summary(False)['money']['max_liability'])

    def test_a_LIVE_rabbit_shows_what_is_actually_riding_on_it(self):
        """The card has to say what is at stake on the hole in front of you,
        which is the leg's own stake plus whatever rolled in."""
        setup_rabbit(self.fs, num_segments=3, accumulate=False)
        for hole in range(1, 9):          # R1 halved, R2 under way
            submit_hole(self.fs, hole, [
                (self.pid[n], 4) for n in ('Ann', 'Ben', 'Cal')])
        calculate_rabbit(self.fs)
        legs = self._legs(self._summary(True))
        self.assertEqual(legs[1][:2], (10.0, 5.0))
        # ...and it rides on THAT leg only, not on every unplayed one after.
        self.assertEqual(legs[2][:2], (5.0, 0.0))

    def test_carried_in_is_zero_everywhere_without_carry(self):
        setup_rabbit(self.fs, num_segments=3, accumulate=False)
        self._play({13: 'Ann'})
        for value, carried, _ in self._legs(self._summary(False)):
            self.assertEqual(carried, 0.0)
            self.assertEqual(value, 5.0)

    def test_the_chip_appears_only_when_it_is_on(self):
        setup_rabbit(self.fs, num_segments=3, carry=True)
        self.assertIn('Carry', rabbit_summary(self.fs)['settings'])
        setup_rabbit(self.fs, num_segments=3, carry=False)
        self.assertNotIn('Carry', rabbit_summary(self.fs)['settings'])


class _RabbitCardBase(TestCase):
    """Fixture only — a sibling that INHERITED the tests would re-run them
    against a fixture they were not written for (`_DayBetBase`)."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round, [('Paul', 0), ('Dave', 0), ('Sam', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup(self, **kw):
        kw.setdefault('accumulate', True)
        kw.setdefault('num_segments', 3)
        kw.setdefault('handicap_mode', 'gross')
        setup_rabbit(self.fs, **kw)

    def _hole(self, h, paul, dave, sam):
        submit_hole(self.fs, h, [(self.pid['Paul'], paul),
                                 (self.pid['Dave'], dave),
                                 (self.pid['Sam'], sam)])

    def _card(self, hole):
        calculate_rabbit(self.fs)
        return rabbit_hole_card(self.fs, hole)


class RabbitHoleCardTests(_RabbitCardBase):
    """`rabbit_hole_card` — what the score-entry screen draws for one hole
    (`~/Downloads/handoff-rabbit-score-entry`)."""

    def test_it_names_the_rabbit_its_range_and_what_is_left(self):
        self._setup()
        r = self._card(10)['rabbit']
        self.assertEqual((r['index'], r['of']), (2, 3))
        self.assertEqual((r['start_hole'], r['end_hole']), (7, 12))
        self.assertEqual(r['to_play'], 3)        # 10, 11, 12
        self.assertTrue(r['loose'])

    def test_the_holder_is_the_state_BEFORE_the_hole(self):
        # Paul catches it on 7 and extends on 8; standing on 9 he is +2, and
        # the hole's own result is what moves it.
        self._setup()
        for h in (7, 8):
            self._hole(h, 3, 5, 5)
        card = self._card(9)
        self.assertEqual(card['rabbit']['holder_short'], 'P')
        self.assertEqual(card['rabbit']['lead'], 2)
        self.assertIsNone(card['result'], 'the 9th is not played yet')

    def test_an_outright_low_lights_one_golfer_and_a_tie_lights_none(self):
        self._setup()
        self._hole(7, 3, 5, 5)
        lit = [p['short'] for p in self._card(7)['players'] if p['is_best']]
        self.assertEqual(lit, ['P'])

        self._hole(8, 4, 4, 5)                   # two share the low
        card = self._card(8)
        self.assertTrue(card['hole_complete'])
        self.assertEqual([p for p in card['players'] if p['is_best']], [],
                         'a tie moves nothing, so it lights nothing')

    def test_the_best_ball_waits_for_the_last_score(self):
        self._setup()
        submit_hole(self.fs, 7, [(self.pid['Paul'], 3)])
        card = self._card(7)
        self.assertFalse(card['hole_complete'])
        self.assertTrue(all(not p['is_best'] for p in card['players']))

    # ── the sentence under the rabbit ─────────────────────────────────────

    def test_catching_it(self):
        self._setup()
        self._hole(7, 3, 5, 5)
        r = self._card(7)['result']
        self.assertEqual(r['event'], 'grab')
        self.assertIn('catches it', r['line'])

    def test_extending_names_what_it_would_take_to_lose_it(self):
        self._setup()
        self._hole(7, 3, 5, 5)
        self._hole(8, 3, 5, 5)
        r = self._card(8)['result']
        self.assertEqual(r['event'], 'extend')
        self.assertIn('Lead up to +2', r['line'])
        self.assertIn('2 losses set it loose', r['line'])

    def test_knocking_it_loose(self):
        self._setup()
        self._hole(7, 3, 5, 5)                   # Paul +1
        self._hole(8, 5, 5, 3)                   # Sam beats him, lead 0
        r = self._card(8)['result']
        self.assertEqual(r['event'], 'freed')
        self.assertIn('knocked it loose', r['line'])
        self.assertIn('the next outright win catches it', r['line'])

    def test_winning_one_back(self):
        self._setup()
        for h in (7, 8):
            self._hole(h, 3, 5, 5)               # Paul +2
        self._hole(9, 5, 3, 5)                   # Dave takes one off
        r = self._card(9)['result']
        self.assertEqual(r['event'], 'beaten')
        self.assertIn('lead down to +1', r['line'])

    def test_a_tie_leaves_it_where_it_is(self):
        # The holder ties for low: nobody won the hole outright, so nothing
        # moves. The engine reports this as HELD — the same event it uses for
        # a holder who WON the hole in stop-after-one mode — so the sentence
        # is chosen on whether there was an outright winner.
        self._setup()
        self._hole(7, 3, 5, 5)
        self._hole(8, 4, 4, 5)
        r = self._card(8)['result']
        self.assertEqual(r['event'], 'held')
        self.assertIsNone(r['winner_short'])
        self.assertIn('stays put', r['line'])

    def test_holding_it_by_winning_is_a_different_sentence(self):
        self._setup(accumulate=False)            # the lead is capped at 1
        self._hole(7, 3, 5, 5)
        self._hole(8, 3, 5, 5)                   # wins it again, still +1
        r = self._card(8)['result']
        self.assertEqual(r['event'], 'held')
        self.assertIn('holds on', r['line'])
        self.assertIn('one loss sets it loose', r['line'])

    # ── decided, and what takes over ──────────────────────────────────────

    def test_a_decided_rabbit_says_so_and_names_the_next_one(self):
        # Rolls on, so the next rabbit KEEPS ITS LENGTH and the leftovers at
        # the end run as an extra.
        self._setup(extra_rabbits=True)
        for h in (7, 8, 9, 10):
            self._hole(h, 3, 5, 5)               # +4 with 2 left on the 10th
        card = self._card(10)
        self.assertTrue(card['result']['decided'])
        self.assertEqual(card['result']['line'], "can't be caught")
        self.assertEqual(card['result']['leg_outcome'], 'won')
        self.assertFalse(card['result']['held_to_end'])
        nxt = card['next']
        self.assertEqual(nxt['start_hole'], 11)
        self.assertEqual(nxt['end_hole'], 16, 'a rabbit keeps its length')
        self.assertFalse(nxt['half_stake'])

    def test_a_rabbit_held_to_the_last_hole_is_won_but_not_early(self):
        self._setup()
        # No rolls-on, so the leg plays out its full range and the rabbit is
        # carried to the 12th rather than won with holes to spare.
        self._hole(7, 3, 5, 5)                   # Paul +1 and holds on
        for h in (8, 9, 10, 11, 12):
            self._hole(h, 4, 4, 4)               # tied all the way in
        r = self._card(12)['result']
        self.assertEqual(r['leg_outcome'], 'won')
        self.assertTrue(r['held_to_end'])

    def test_a_rabbit_nobody_held_ends_loose(self):
        self._setup()
        for h in range(7, 13):
            self._hole(h, 4, 4, 4)               # never caught
        r = self._card(12)['result']
        self.assertEqual(r['leg_outcome'], 'loose')

    def test_a_hole_mid_leg_has_not_ended_it(self):
        self._setup()
        self._hole(7, 3, 5, 5)
        self.assertFalse(self._card(7)['result']['leg_ended'])

    def test_a_live_rabbit_offers_no_next_one(self):
        self._setup(extra_rabbits=True)
        self._hole(7, 3, 5, 5)
        card = self._card(7)
        self.assertFalse(card['result']['decided'])
        self.assertIsNone(card['next'])

    def test_a_one_hole_extra_is_flagged_as_half(self):
        self._setup(extra_rabbits=True)
        for h in range(1, 7):                    # rabbit 1 runs its length
            self._hole(h, 4, 4, 4)
        # Decided on the 11th, not before: +1, +1, +2, +2, then +3 with one
        # hole left. A clean sweep would have settled it on the 10th.
        self._hole(7, 3, 5, 5)
        self._hole(8, 4, 4, 4)
        self._hole(9, 3, 5, 5)
        self._hole(10, 4, 4, 4)
        self._hole(11, 3, 5, 5)
        card = self._card(11)
        self.assertTrue(card['result']['decided'])
        # Rabbit 3 takes 12–17 and the 18th is left over.
        self.assertEqual((card['next']['start_hole'],
                          card['next']['end_hole']), (12, 17))
        tail = self._card(18)['rabbit']
        self.assertTrue(tail['is_extra'])
        self.assertEqual(tail['stake'], 2.5, 'one hole pays half')

    # ── the rest ──────────────────────────────────────────────────────────

    def test_the_rows_carry_a_stable_colour_and_the_handicap(self):
        self._setup()
        rows = {p['short']: p for p in self._card(7)['players']}
        self.assertEqual({p['colour_index'] for p in rows.values()}, {0, 1, 2})
        self.assertEqual(rows['P']['course_handicap'], 0)

    def test_strokes_are_the_RABBIT_allocation(self):
        # The round is net; this game is gross, and the dots follow the game.
        self.fs.memberships.filter(player_id=self.pid['Sam']).update(
            playing_handicap=18, course_handicap=18)
        self._setup()
        self._hole(7, 4, 4, 5)
        rows = {p['short']: p for p in self._card(7)['players']}
        self.assertEqual(rows['S']['strokes'], 0)
        self.assertEqual(rows['S']['net'], rows['S']['gross'])

    def test_the_hole_carries_its_par_index_and_nine(self):
        self._setup()
        card = self._card(10)
        self.assertEqual(card['par'], self.tee.hole(10)['par'])
        self.assertEqual(card['nine'], 'back nine')
        self.assertEqual(self._card(7)['nine'], 'front nine')

    def test_no_game_returns_nothing(self):
        self.assertEqual(rabbit_hole_card(self.fs, 1), {})


class RabbitFixtureRegenTests(_RabbitCardBase):
    """Writes the JSON the Flutter tests draw, from the REAL engine.

    `REGEN_RABBIT_FIXTURES=1 manage.py test scoring.tests.test_rabbit`
    rewrites them — the Sequoya arrangement. A screen tested against
    hand-written JSON is tested against what somebody THOUGHT the server
    sends.
    """

    def _write(self, name, card):
        import json, os, pathlib
        if os.environ.get('REGEN_RABBIT_FIXTURES') != '1':
            return
        path = (pathlib.Path(__file__).resolve().parents[2]
                / 'mobile' / 'test' / 'fixtures' / name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(card, indent=2, default=str) + '\n')

    def test_regenerate(self):
        # Rolls on, carry, strokes off the low man — the packet's settings.
        self.fs.memberships.filter(player_id=self.pid['Dave']).update(
            playing_handicap=4, course_handicap=4)
        self.fs.memberships.filter(player_id=self.pid['Sam']).update(
            playing_handicap=7, course_handicap=7)
        self._setup(extra_rabbits=True, carry=True,
                    handicap_mode='strokes_off')

        for h in range(1, 7):
            self._hole(h, 4, 4, 4)               # rabbit 1 never caught
        self._hole(7, 3, 6, 6)
        self._hole(8, 3, 6, 6)

        # 1 · mid-rabbit, one score still out.
        submit_hole(self.fs, 9, [(self.pid['Paul'], 4),
                                 (self.pid['Dave'], 6)])
        live = self._card(9)
        self.assertFalse(live['hole_complete'])
        self._write('rabbit_hole9_live.json', live)

        # 2 · the hole lands and the lead goes up.
        self._hole(9, 4, 6, 6)
        up = self._card(9)
        self.assertEqual(up['result']['event'], 'extend')
        self._write('rabbit_hole9_lead_up.json', up)

    def test_regenerate_won_early(self):
        self._setup(extra_rabbits=True, carry=True)
        for h in range(1, 7):
            self._hole(h, 4, 4, 4)
        for h in (7, 8, 9, 10):
            self._hole(h, 3, 5, 5)               # +4 with 2 left
        card = self._card(10)
        self.assertTrue(card['result']['decided'])
        self.assertIsNotNone(card['next'])
        self._write('rabbit_hole10_won_early.json', card)

    def test_regenerate_knocked_loose(self):
        self._setup(extra_rabbits=True, carry=True)
        self._hole(7, 3, 5, 5)                   # Paul +1
        self._hole(8, 5, 5, 3)                   # Sam frees it
        card = self._card(8)
        self.assertEqual(card['result']['event'], 'freed')
        self._write('rabbit_hole8_loose.json', card)
