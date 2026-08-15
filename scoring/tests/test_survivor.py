"""
scoring/tests/test_survivor.py
------------------------------
Regression tests for services/survivor.py — the 3-player horse race.

Gross mode keeps the score math obvious; the handicap modes get their own
tests at the bottom.

Naming convention in here: Ann / Ben / Cal, and a hole is written as the three
gross scores in that order.
"""
from django.test import TestCase

from services.survivor import (
    calculate_survivor,
    setup_survivor,
    survivor_summary,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class SurvivorTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = 5
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 0), ('Cal', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.sn = {m.player.name: m.player.short_name
                   for m in self.fs.memberships.select_related('player')}
        setup_survivor(self.fs, handicap_mode='gross')

    # ── Helpers ──────────────────────────────────────────────────────────────

    def _abc(self):
        return self.pid['Ann'], self.pid['Ben'], self.pid['Cal']

    def _play(self, hole, a, b, c):
        A, B, C = self._abc()
        submit_hole(self.fs, hole, [(A, a), (B, b), (C, c)])

    def _summary(self):
        calculate_survivor(self.fs)
        return survivor_summary(self.fs)

    def _legs(self, s):
        """[(index, start, end, eliminated, winner, outcome)] per Survivor."""
        return [(x['index'], x['start_hole'], x['end_hole'],
                 x['eliminated_short'], x['winner_short'], x['outcome'])
                for x in s['survivors']]

    def _money(self, s):
        return {p['short_name']: p['money'] for p in s['players']}

    def _event(self, s, hole):
        h = next(x for x in s['holes'] if x['hole'] == hole)
        return h['role'], h['event']

    # ── Elimination phase ────────────────────────────────────────────────────

    def test_worst_score_is_eliminated(self):
        self._play(1, 4, 5, 6)                      # Cal worst
        s = self._summary()
        assert self._event(s, 1) == ('elimination', 'eliminated'), self._event(s, 1)
        assert s['survivors'][0]['eliminated_short'] == self.sn['Cal']
        # Cal is out for the rest of THIS Survivor.
        assert s['current']['alive_ids'] == [self.pid['Ann'], self.pid['Ben']]
        assert s['current']['role'] == 'decider'

    def test_two_worst_tied_eliminates_nobody(self):
        # Ben and Cal tie for worst — nobody goes, all three carry on.
        self._play(1, 4, 6, 6)
        s = self._summary()
        assert self._event(s, 1) == ('elimination', 'no_elimination')
        assert s['current']['alive_ids'] == list(self.pid.values())
        assert s['current']['role'] == 'elimination'
        # Still Survivor 1 — a no-elimination hole doesn't start a new one.
        assert s['current']['survivor'] == 1

    def test_all_three_tied_eliminates_nobody(self):
        self._play(1, 4, 4, 4)
        s = self._summary()
        assert self._event(s, 1) == ('elimination', 'no_elimination')

    def test_tie_for_low_does_not_block_elimination(self):
        # Only the BOTTOM of the board matters: Ann and Ben tie for low, but
        # Cal is still uniquely worst, so Cal goes.
        self._play(1, 4, 4, 6)
        s = self._summary()
        assert self._event(s, 1) == ('elimination', 'eliminated')
        assert s['survivors'][0]['eliminated_short'] == self.sn['Cal']

    # ── Decider phase ────────────────────────────────────────────────────────

    def test_decider_low_ball_wins_the_survivor(self):
        self._play(1, 4, 5, 6)                      # Cal out
        self._play(2, 4, 5, 4)                      # Ann beats Ben (Cal ignored)
        s = self._summary()
        assert self._event(s, 2) == ('decider', 'won')
        assert self._legs(s)[0] == (1, 1, 2, self.sn['Cal'], self.sn['Ann'], 'won')
        # Winner takes both entries.
        assert self._money(s) == {self.sn['Ann']: 10.0,
                                  self.sn['Ben']: -5.0,
                                  self.sn['Cal']: -5.0}

    def test_eliminated_players_score_is_ignored_in_the_decider(self):
        # Cal is out but still posts the low gross — it must not win the
        # Survivor for him, nor stop Ann beating Ben.
        self._play(1, 4, 5, 6)                      # Cal out
        self._play(2, 5, 6, 2)                      # Cal's 2 is irrelevant
        s = self._summary()
        assert self._legs(s)[0][4] == self.sn['Ann'], self._legs(s)
        assert self._money(s)[self.sn['Cal']] == -5.0

    def test_tied_decider_carries_to_the_next_hole(self):
        self._play(1, 4, 5, 6)                      # Cal out
        self._play(2, 4, 4, 4)                      # tied → carry
        self._play(3, 4, 5, 4)                      # Ann wins
        s = self._summary()
        assert self._event(s, 2) == ('decider', 'carried')
        assert self._legs(s)[0] == (1, 1, 3, self.sn['Cal'], self.sn['Ann'], 'won')

    def test_a_survivor_can_run_many_holes(self):
        self._play(1, 4, 4, 4)                      # no elimination
        self._play(2, 5, 5, 4)                      # two worst tie → none
        self._play(3, 4, 5, 6)                      # Cal out
        self._play(4, 4, 4, 4)                      # carry
        self._play(5, 4, 4, 4)                      # carry
        self._play(6, 5, 4, 4)                      # Ben wins
        s = self._summary()
        assert self._legs(s)[0] == (1, 1, 6, self.sn['Cal'], self.sn['Ben'], 'won')

    # ── Survivor sequencing ──────────────────────────────────────────────────

    def test_next_survivor_starts_on_the_very_next_hole(self):
        self._play(1, 4, 5, 6)                      # Cal out
        self._play(2, 4, 5, 4)                      # Ann wins Survivor 1
        self._play(3, 6, 5, 4)                      # Survivor 2: Ann out
        s = self._summary()
        legs = self._legs(s)
        assert legs[0][:3] == (1, 1, 2), legs
        assert legs[1][:4] == (2, 3, 3, self.sn['Ann']), legs
        # All three were back in on hole 3.
        h3 = next(x for x in s['holes'] if x['hole'] == 3)
        assert all(e['is_alive'] for e in h3['entries']), h3

    def test_nine_survivors_is_the_maximum_over_eighteen(self):
        # Every Survivor takes the minimum two holes: elimination then decider.
        for h in range(1, 19, 2):
            self._play(h,     4, 5, 6)              # Cal out
            self._play(h + 1, 4, 5, 4)              # Ann wins
        s = self._summary()
        assert len(s['survivors']) == 9, self._legs(s)
        assert all(x['outcome'] == 'won' for x in s['survivors'])
        assert self._money(s) == {self.sn['Ann']: 90.0,
                                  self.sn['Ben']: -45.0,
                                  self.sn['Cal']: -45.0}
        assert s['status'] == 'complete'

    # ── The last hole ────────────────────────────────────────────────────────

    def _to_hole(self, upto):
        """Win a Survivor every two holes up to (not including) `upto`."""
        for h in range(1, upto, 2):
            self._play(h,     4, 5, 6)
            self._play(h + 1, 4, 5, 4)

    def test_last_hole_with_three_alive_low_ball_wins(self):
        self._to_hole(17)                           # 8 Survivors, holes 1-16
        self._play(17, 4, 4, 4)                     # no elimination
        self._play(18, 4, 5, 6)                     # three alive on the last
        s = self._summary()
        assert self._event(s, 18) == ('final', 'won')
        assert self._legs(s)[-1] == (9, 17, 18, None, self.sn['Ann'], 'won')

    def test_last_hole_with_three_alive_tied_for_low_is_no_blood(self):
        self._to_hole(17)
        self._play(17, 4, 4, 4)                     # no elimination
        self._play(18, 4, 4, 6)                     # tied for low
        s = self._summary()
        assert self._event(s, 18) == ('final', 'no_blood')
        last = s['survivors'][-1]
        assert last['outcome'] == 'no_blood' and last['payout'] == 0.0, last
        # Survivor 9 moved no money — the totals are the first eight only.
        assert self._money(s) == {self.sn['Ann']: 80.0,
                                  self.sn['Ben']: -40.0,
                                  self.sn['Cal']: -40.0}

    def test_last_hole_with_three_alive_all_tied_is_no_blood(self):
        self._to_hole(17)
        self._play(17, 5, 5, 5)
        self._play(18, 4, 4, 4)
        s = self._summary()
        assert self._event(s, 18) == ('final', 'no_blood')

    def test_a_survivor_starting_on_the_last_hole_is_low_ball(self):
        # A Survivor that ENDS on 17 leaves a fresh one starting on 18 with all
        # three in — the "new match on the last hole" case.  Survivor 1 takes
        # three holes (a carried decider), which shifts every later boundary
        # onto odd holes so Survivor 8 ends on 17.
        self._play(1, 4, 5, 6)                      # Cal out
        self._play(2, 4, 4, 4)                      # tied → carry
        self._play(3, 4, 5, 4)                      # Ann wins (holes 1-3)
        for h in range(4, 18, 2):                   # Survivors 2-8, holes 4-17
            self._play(h,     4, 5, 6)
            self._play(h + 1, 4, 5, 4)
        self._play(18, 6, 4, 5)                     # Survivor 9 = hole 18 alone
        s = self._summary()
        legs = self._legs(s)
        assert len(legs) == 9, legs
        assert legs[-1] == (9, 18, 18, None, self.sn['Ben'], 'won'), legs
        assert self._event(s, 18) == ('final', 'won')
        # It really was a one-hole Survivor, and it paid like any other.
        assert s['survivors'][-1]['holes'] == 1
        assert self._money(s)[self.sn['Ben']] == -30.0      # -8 x 5 + 10

    def test_last_hole_decider_tie_splits_the_eliminated_players_entry(self):
        self._to_hole(17)                           # 8 Survivors, holes 1-16
        self._play(17, 4, 5, 6)                     # Cal out
        self._play(18, 4, 4, 3)                     # Ann + Ben tie on the last
        s = self._summary()
        assert self._event(s, 18) == ('final', 'split')
        last = s['survivors'][-1]
        assert last['outcome'] == 'split', last
        assert last['eliminated_short'] == self.sn['Cal'] and last['winner_short'] is None
        # +½ / +½ / −1 on top of the eight Ann already won.
        assert self._money(s) == {self.sn['Ann']: 82.5,
                                  self.sn['Ben']: -37.5,
                                  self.sn['Cal']: -45.0}

    # ── Money ────────────────────────────────────────────────────────────────

    def test_settlement_is_zero_sum_across_a_mixed_round(self):
        self._play(1, 4, 5, 6); self._play(2, 4, 5, 4)      # Ann wins
        self._play(3, 6, 4, 5); self._play(4, 4, 4, 4)      # carry
        self._play(5, 4, 5, 4)                              # Cal wins
        self._play(6, 4, 4, 4)                              # no elimination
        self._play(7, 5, 4, 6); self._play(8, 4, 4, 4)      # carry
        self._play(9, 4, 3, 4)                              # Ben wins
        for h in range(10, 17):
            self._play(h, 4, 4, 4)                          # nothing settles
        self._play(17, 4, 5, 6)                             # Cal out
        self._play(18, 4, 4, 4)                             # split on the last
        s = self._summary()
        money = self._money(s)
        assert abs(sum(money.values())) < 1e-9, money

    def test_live_survivor_pays_nobody(self):
        self._play(1, 4, 5, 6)                      # Cal out, nothing decided
        s = self._summary()
        assert s['survivors'][0]['outcome'] == 'live'
        assert self._money(s) == {self.sn['Ann']: 0.0,
                                  self.sn['Ben']: 0.0,
                                  self.sn['Cal']: 0.0}
        assert s['status'] == 'in_progress'

    def test_max_liability_tracks_the_holes_in_play(self):
        s = self._summary()
        assert s['money']['max_liability'] == 45.0      # 9 Survivors × $5
        assert s['money']['pot'] == 15.0                # three entries

    # ── Unscored holes ───────────────────────────────────────────────────────

    def test_unscored_hole_is_skipped_and_state_carries(self):
        self._play(1, 4, 5, 6)                      # Cal out
        self._play(3, 4, 5, 4)                      # hole 2 never posted
        s = self._summary()
        assert self._legs(s)[0] == (1, 1, 3, self.sn['Cal'], self.sn['Ann'], 'won')
        assert self._event(s, 2) == (None, None)

    # ── Handicaps ────────────────────────────────────────────────────────────

    def test_net_handicap_decides_the_elimination(self):
        # Cal is a 9 and gets a stroke on hole 5 (SI 1); on gross he'd be worst,
        # on net he isn't — Ben goes instead.
        rnd = make_round(self.tee.course)
        rnd.bet_unit = 5
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('Ann', 0), ('Ben', 0), ('Cal', 9)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_survivor(fs, handicap_mode='net')
        submit_hole(fs, 5, [(pid['Ann'], 4), (pid['Ben'], 6), (pid['Cal'], 5)])
        calculate_survivor(fs)
        s = survivor_summary(fs)
        h = next(x for x in s['holes'] if x['hole'] == 5)
        assert h['eliminated_id'] == pid['Ben'], h
        cal = next(e for e in h['entries'] if e['player_id'] == pid['Cal'])
        assert cal['strokes'] == 1 and cal['net_score'] == 4, cal

    def test_strokes_off_anchors_on_the_low_handicap(self):
        rnd = make_round(self.tee.course)
        rnd.bet_unit = 5
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('Ann', 4), ('Ben', 4), ('Cal', 13)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_survivor(fs, handicap_mode='strokes_off')
        calculate_survivor(fs)
        s = survivor_summary(fs)
        phcp = {p['short_name']: p['phcp_in_play'] for p in s['players']}
        # The low pair play to scratch; Cal plays off the 9-shot difference.
        assert phcp == {'A': 0, 'B': 0, 'C': 9}, phcp

    def test_gross_mode_issues_no_strokes(self):
        rnd = make_round(self.tee.course)
        rnd.bet_unit = 5
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('Ann', 0), ('Ben', 0), ('Cal', 18)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_survivor(fs, handicap_mode='gross')
        submit_hole(fs, 1, [(pid['Ann'], 4), (pid['Ben'], 5), (pid['Cal'], 6)])
        calculate_survivor(fs)
        s = survivor_summary(fs)
        h = next(x for x in s['holes'] if x['hole'] == 1)
        assert all(e['strokes'] == 0 for e in h['entries']), h
        assert h['eliminated_id'] == pid['Cal'], h

    # ── Partial rounds / shotgun ─────────────────────────────────────────────

    def test_back_nine_round_uses_its_own_last_hole(self):
        # A 9-hole round starting on 10: "the last hole" is 18, and the whole
        # sequence runs over the 9 played holes only.
        self.round.num_holes = 9
        self.round.starting_hole = 10
        self.round.save(update_fields=['num_holes', 'starting_hole'])
        for h in (10, 12, 14, 16):
            self._play(h,     4, 5, 6)              # Cal out
            self._play(h + 1, 4, 5, 4)              # Ann wins
        self._play(18, 4, 4, 4)                     # three alive, tied → no blood
        s = self._summary()
        assert [h['hole'] for h in s['holes']] == list(range(10, 19))
        assert len(s['survivors']) == 5, self._legs(s)
        assert s['survivors'][-1]['outcome'] == 'no_blood'
        assert s['status'] == 'complete'
        # Four 2-hole Survivors plus a 1-hole one on the last: (9 + 1) // 2 = 5.
        assert s['money']['max_liability'] == 25.0

    # ── Scorecard block ──────────────────────────────────────────────────────

    def test_summary_emits_a_scorecard_block(self):
        self._play(1, 4, 5, 6)
        s = self._summary()
        sc = s['scorecard']
        A, B, C = self._abc()
        assert [p['player_id'] for p in sc['players']] == [A, B, C]
        assert sc['holes_in_play'] == list(range(1, 19))
        h1 = next(h for h in sc['holes'] if h['hole'] == 1)
        assert h1['par'] == 4 and h1['stroke_index'] == 7, h1
        assert {x['player_id']: x['gross'] for x in h1['scores']} == {A: 4, B: 5, C: 6}
