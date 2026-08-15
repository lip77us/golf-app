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

    def test_setup_defaults_to_per_segment(self):
        g = setup_rabbit(self.fs, handicap_mode='strokes_off', num_segments=3)
        assert g.handicap_allocation == 'per_segment'

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
