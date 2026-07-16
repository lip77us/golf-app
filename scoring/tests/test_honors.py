"""
scoring/tests/test_honors.py
----------------------------
Regression tests for services/honors.py — the carry-token points game.

Rules under test:
  * Winning a hole outright (strictly lowest score-to-compare) takes the
    honor; the holder keeps it until another player wins a hole outright.
  * A tied hole never beats the holder (they keep it) and a still-loose
    honor stays loose on a tie.
  * The holder scores 1 point per hole held, so points == holes held.
  * Settlement via the shared wager engine (vs-average / pay-above /
    pay-leader / pool), always zero-sum.

Gross mode keeps the score math obvious; a Net test covers stroke
allocation, and a Strokes-Off test covers the low-plays-to-zero anchor.
"""
from django.test import TestCase

from services.honors import calculate_honors, setup_honors, honors_summary

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class HonorsTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = 1
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

    def _hole(self, summary, hole):
        return next(x for x in summary['holes'] if x['hole'] == hole)

    def _points(self, summary):
        return {p['short_name']: p['points'] for p in summary['players']}

    def _money(self, summary):
        return {p['short_name']: p['money'] for p in summary['players']}

    # ── Carry / transfer / tie ───────────────────────────────────────────────

    def test_outright_win_takes_and_holds_the_honor(self):
        setup_honors(self.fs, handicap_mode='gross')
        # H1 Ann wins → holds.  H2 tie for low (Ann & Ben) → Ann keeps it.
        # H3 Ben wins outright → honor transfers to Ben.
        submit_hole(self.fs, 1, [(self.pid['Ann'], 4), (self.pid['Ben'], 5),
                                  (self.pid['Cal'], 6)])
        submit_hole(self.fs, 2, [(self.pid['Ann'], 5), (self.pid['Ben'], 5),
                                  (self.pid['Cal'], 6)])
        submit_hole(self.fs, 3, [(self.pid['Ann'], 5), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 6)])
        calculate_honors(self.fs)
        s = honors_summary(self.fs)
        assert self._hole(s, 1)['holder_short'] == self.sn['Ann']
        assert self._hole(s, 1)['winner_short'] == self.sn['Ann']
        # Tie hole: holder kept, but no outright winner.
        assert self._hole(s, 2)['holder_short'] == self.sn['Ann']
        assert self._hole(s, 2)['winner_short'] is None
        assert self._hole(s, 3)['holder_short'] == self.sn['Ben']
        # Ann held H1+H2 (2), Ben held H3 (1), Cal none.
        assert self._points(s) == {self.sn['Ann']: 2, self.sn['Ben']: 1,
                                   self.sn['Cal']: 0}, self._points(s)

    def test_loose_until_first_outright_win(self):
        setup_honors(self.fs, handicap_mode='gross')
        # H1 three-way tie → nobody holds, no point awarded.
        submit_hole(self.fs, 1, [(self.pid['Ann'], 4), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])
        # H2 Cal wins → Cal holds.
        submit_hole(self.fs, 2, [(self.pid['Ann'], 5), (self.pid['Ben'], 5),
                                  (self.pid['Cal'], 4)])
        calculate_honors(self.fs)
        s = honors_summary(self.fs)
        assert self._hole(s, 1)['holder_short'] is None
        assert self._hole(s, 2)['holder_short'] == self.sn['Cal']
        assert self._points(s) == {self.sn['Ann']: 0, self.sn['Ben']: 0,
                                   self.sn['Cal']: 1}, self._points(s)

    def test_tie_below_holder_still_keeps_holder(self):
        # A tie for low never beats the holder, even when both other
        # players score below the holder — "a tie doesn't beat you".
        setup_honors(self.fs, handicap_mode='gross')
        submit_hole(self.fs, 1, [(self.pid['Ann'], 3), (self.pid['Ben'], 5),
                                  (self.pid['Cal'], 5)])            # Ann holds
        submit_hole(self.fs, 2, [(self.pid['Ann'], 6), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 4)])            # Ben & Cal tie low
        calculate_honors(self.fs)
        s = honors_summary(self.fs)
        assert self._hole(s, 2)['winner_short'] is None
        assert self._hole(s, 2)['holder_short'] == self.sn['Ann']
        assert self._points(s)[self.sn['Ann']] == 2

    def test_unscored_hole_carries_state(self):
        setup_honors(self.fs, handicap_mode='gross')
        submit_hole(self.fs, 1, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 5)])            # Ann holds
        # Hole 2 left unscored (skipped) — the honor carries but no point.
        submit_hole(self.fs, 3, [(self.pid['Ann'], 5), (self.pid['Ben'], 4),
                                  (self.pid['Cal'], 6)])            # Ben wins
        calculate_honors(self.fs)
        s = honors_summary(self.fs)
        # Hole 2 was never scored, so it awards no point and records no
        # holder; the honor simply carries to hole 3's winner.
        assert self._hole(s, 2)['holder_short'] is None, self._hole(s, 2)
        assert self._points(s) == {self.sn['Ann']: 1, self.sn['Ben']: 1,
                                   self.sn['Cal']: 0}, self._points(s)
        assert s['status'] == 'in_progress'

    # ── Settlement ───────────────────────────────────────────────────────────

    def _hold_pattern(self):
        """Ann holds 3 holes, Ben 1, Cal 1 → points {3,1,1}."""
        # H1-3 Ann wins; H4 Ben wins; H5 Cal wins.
        for h in (1, 2, 3):
            submit_hole(self.fs, h, [(self.pid['Ann'], 3), (self.pid['Ben'], 4),
                                      (self.pid['Cal'], 5)])
        submit_hole(self.fs, 4, [(self.pid['Ann'], 5), (self.pid['Ben'], 3),
                                  (self.pid['Cal'], 6)])
        submit_hole(self.fs, 5, [(self.pid['Ann'], 5), (self.pid['Ben'], 6),
                                  (self.pid['Cal'], 3)])

    def test_vs_average_settlement_zero_sum(self):
        self.round.bet_unit = 2
        self.round.save(update_fields=['bet_unit'])
        setup_honors(self.fs, handicap_mode='gross',
                     payout_style='per_point', per_point_mode='average')
        self._hold_pattern()
        calculate_honors(self.fs)
        s = honors_summary(self.fs)
        assert self._points(s) == {self.sn['Ann']: 3, self.sn['Ben']: 1,
                                   self.sn['Cal']: 1}
        money = self._money(s)
        # points {3,1,1}, total 5, avg 5/3, rate 2:
        # Ann (3-5/3)*2 = +2.67 ; Ben/Cal (1-5/3)*2 = -1.33 each.  (The engine
        # reconciles the final penny to keep the table exactly zero-sum, so
        # assert the shape rather than an exact cent.)
        assert round(money[self.sn['Ann']], 1) == 2.7, money
        assert money[self.sn['Ann']] > money[self.sn['Ben']], money
        assert abs(sum(money.values())) < 1e-6, money

    def test_pay_leader_and_pay_above_and_pool_zero_sum(self):
        for mode, style in [('first', 'per_point'), ('all', 'per_point')]:
            self.fs.honors_game.delete() if hasattr(self.fs, 'honors_game') else None
            setup_honors(self.fs, handicap_mode='gross',
                         payout_style=style, per_point_mode=mode)
            self._hold_pattern()
            calculate_honors(self.fs)
            s = honors_summary(self.fs)
            money = self._money(s)
            assert abs(sum(money.values())) < 1e-6, (mode, money)
            # The point leader (Ann, 3 pts) is never a net loser.
            assert money[self.sn['Ann']] >= 0, (mode, money)
        # Pool: everyone antes bet_unit; split by share of points.
        setup_honors(self.fs, handicap_mode='gross', payout_style='pool')
        self._hold_pattern()
        calculate_honors(self.fs)
        s = honors_summary(self.fs)
        assert abs(sum(self._money(s).values())) < 1e-6

    # ── Auto-init when active but unconfigured ───────────────────────────────

    def test_auto_inits_when_active_but_not_set_up(self):
        # Honors added as a side game (in active_games) but the setup screen was
        # never completed → no HonorsGame row. calculate_honors should auto-init
        # with defaults and score from the entered gross, instead of the
        # leaderboard sitting at "not started".
        r = make_round(self.tee.course, active_games=['points_531', 'honors'])
        r.bet_unit = 1
        r.save(update_fields=['bet_unit'])
        fs = make_foursome(r, [('Al', 0), ('Bo', 0), ('Cy', 0)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        submit_hole(fs, 1, [(pid['Al'], 4), (pid['Bo'], 5), (pid['Cy'], 6)])
        submit_hole(fs, 2, [(pid['Al'], 5), (pid['Bo'], 4), (pid['Cy'], 6)])
        # No setup_honors() call — simulate an unconfigured side game; the
        # summary starts out "not started".
        assert honors_summary(fs)['status'] == 'pending'
        calculate_honors(fs)
        s = honors_summary(fs)
        assert s['status'] == 'in_progress', s['status']
        # Default handicap is Strokes-Off Low.
        assert s['handicap']['mode'] == 'strokes_off', s['handicap']
        # Al won hole 1, Bo won hole 2 → 1 point each.
        pts = {p['short_name']: p['points'] for p in s['players']}
        assert sum(pts.values()) == 2, pts

    def test_does_not_auto_init_when_not_active(self):
        # calculate_honors on a round without 'honors' active is a no-op.
        r = make_round(self.tee.course, active_games=['points_531'])
        fs = make_foursome(r, [('Al', 0), ('Bo', 0), ('Cy', 0)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        submit_hole(fs, 1, [(pid['Al'], 4), (pid['Bo'], 5), (pid['Cy'], 6)])
        calculate_honors(fs)
        s = honors_summary(fs)
        assert s['status'] == 'pending', s['status']

    # ── Participant subset ───────────────────────────────────────────────────

    def test_participant_subset_restricts_the_game(self):
        # Only Ann and Ben are in; Cal is excluded even though Cal has the low
        # gross on hole 1 — the honor is decided among participants only.
        setup_honors(self.fs, handicap_mode='gross',
                     participant_player_ids=[self.pid['Ann'], self.pid['Ben']])
        submit_hole(self.fs, 1, [(self.pid['Ann'], 4), (self.pid['Ben'], 5),
                                  (self.pid['Cal'], 3)])   # Cal low, but out
        calculate_honors(self.fs)
        s = honors_summary(self.fs)
        # Cal is absent from the standings; among Ann/Ben, Ann wins the hole.
        assert {p['short_name'] for p in s['players']} == \
            {self.sn['Ann'], self.sn['Ben']}, s['players']
        assert self._hole(s, 1)['holder_short'] == self.sn['Ann']
        assert self._points(s)[self.sn['Ann']] == 1
        assert s['participant_player_ids'] == \
            [self.pid['Ann'], self.pid['Ben']]
        # Two-player subset still settles zero-sum.
        assert abs(sum(self._money(s).values())) < 1e-6

    def test_empty_participant_list_means_everyone(self):
        setup_honors(self.fs, handicap_mode='gross', participant_player_ids=[])
        submit_hole(self.fs, 1, [(self.pid['Ann'], 4), (self.pid['Ben'], 5),
                                  (self.pid['Cal'], 3)])
        calculate_honors(self.fs)
        s = honors_summary(self.fs)
        assert len(s['players']) == 3
        assert self._hole(s, 1)['holder_short'] == self.sn['Cal']

    # ── Handicap modes ───────────────────────────────────────────────────────

    def test_net_mode_allocates_strokes(self):
        # Cal gets 18 strokes (one per hole); on hole 1 (par 4, SI 7) Cal's
        # gross 5 nets to 4, beating Ann's gross 4 / net 4? tie -> use SI.
        r = make_round(self.tee.course)
        r.bet_unit = 1
        r.save(update_fields=['bet_unit'])
        fs = make_foursome(r, [('Amy', 0), ('Bo', 0), ('Cy', 18)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        sn = {m.player.name: m.player.short_name
              for m in fs.memberships.select_related('player')}
        setup_honors(fs, handicap_mode='net', net_percent=100)
        # Hole 1: Cy gross 5 − 1 stroke = net 4; Amy gross 5, Bo gross 6.
        # Cy wins outright on net.
        submit_hole(fs, 1, [(pid['Amy'], 5), (pid['Bo'], 6), (pid['Cy'], 5)])
        calculate_honors(fs)
        s = honors_summary(fs)
        h1 = next(x for x in s['holes'] if x['hole'] == 1)
        assert h1['holder_short'] == sn['Cy'], h1

    def test_strokes_off_low_plays_to_zero(self):
        r = make_round(self.tee.course)
        r.bet_unit = 1
        r.save(update_fields=['bet_unit'])
        # Low handicap (Amy, 0) plays to 0; Cy (10) gets strokes off the low.
        fs = make_foursome(r, [('Amy', 0), ('Bo', 0), ('Cy', 10)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_honors(fs, handicap_mode='strokes_off', net_percent=100)
        calculate_honors(fs)
        s = honors_summary(fs)
        phcp = {p['short_name']: p['phcp_in_play'] for p in s['players']}
        # Amy is the low → plays to 0; Cy gets 10 strokes.
        amy_sn = next(m.player.short_name for m in fs.memberships.select_related('player')
                      if m.player.name == 'Amy')
        cy_sn = next(m.player.short_name for m in fs.memberships.select_related('player')
                     if m.player.name == 'Cy')
        assert phcp[amy_sn] == 0, phcp
        assert phcp[cy_sn] == 10, phcp
