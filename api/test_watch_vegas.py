"""
api/test_watch_vegas.py
-----------------------
Public web-watcher tab for Las Vegas (2v2). Renders each team's amount up/down +
points, holes played, and highlights the biggest single-hole swing so far.
"""
from decimal import Decimal

from django.test import TestCase, Client

from scoring.tests._helpers import (
    make_course, make_tee, make_round, make_foursome, make_player, submit_hole)
from services.vegas import setup_vegas, calculate_vegas


class VegasWatchPageTests(TestCase):
    def setUp(self):
        self.tee = make_tee(make_course())
        self.round = make_round(self.tee.course, active_games=['vegas'])
        self.round.bet_unit = Decimal('5.00')
        self.round.save(update_fields=['bet_unit'])
        self.p = [make_player(n, 0, short_name=n) for n in ('A', 'B', 'C', 'D')]
        self.fs = make_foursome(
            self.round, [(pl, 0) for pl in self.p], tee=self.tee)
        setup_vegas(
            self.fs, [self.p[0].id, self.p[1].id], [self.p[2].id, self.p[3].id],
            handicap_mode='gross', net_percent=100, net_max_double_bogey=False,
            birdie_mode='flip', carryover=False, loss_cap=None)

    def _play(self, hole, a, b, c, d):
        submit_hole(self.fs, hole, [
            (self.p[0], a), (self.p[1], b), (self.p[2], c), (self.p[3], d)])
        calculate_vegas(self.fs)

    def test_tab_appears_in_nav(self):
        resp = Client().get(f'/watch/{self.round.watch_token}/')
        self.assertEqual(resp.status_code, 200)
        self.assertIn('view=vegas', resp.content.decode())

    def test_vegas_tab_renders_with_biggest_hole(self):
        # Hole 1: small swing (team1 wins 45 vs 46 by 1).
        self._play(1, 4, 5, 4, 6)
        # Hole 2 (par 4): C birdie (gross 3) flips team1 56→65; team2 34 wins by
        # 31 — the biggest swing of the round.
        self._play(2, 5, 6, 3, 4)
        resp = Client().get(f'/watch/{self.round.watch_token}/?view=vegas')
        self.assertEqual(resp.status_code, 200)
        html = resp.content.decode()
        self.assertIn('Las Vegas', html)
        self.assertIn('Biggest hole', html)
        self.assertIn('#2', html)               # hole 2 is the biggest swing
        self.assertIn('+31 pts', html)          # the swing size
        self.assertIn('$155', html)             # 31 pts × $5 = $155
        self.assertIn('2 holes scored', html)
