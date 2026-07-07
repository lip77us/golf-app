"""
scoring/tests/test_settlement.py
--------------------------------
Cross-game settlement: round_settlement sums each game's signed per-player
net into one zero-sum "who owes whom" summary.
"""
from collections import defaultdict
from decimal import Decimal

from django.test import TestCase

from services.skins import setup_skins, calculate_skins, skins_summary
from services.spots import setup_spots, tally_spots, spots_summary
from services.settlement import _pid_nets_for_game, round_settlement
from ._helpers import make_tee, make_round, make_foursome, submit_round


class SettlementTests(TestCase):
    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['skins', 'spots'])
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round, [('A', 0), ('B', 0), ('C', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def test_settlement_sums_individual_game_nets(self):
        setup_skins(self.fs)  # pool (default)
        setup_spots(self.fs, bet_unit=Decimal('1'),
                    payout_style='per_point', per_point_mode='all')
        # A beats B beats C on every hole → A sweeps the skins.
        submit_round(self.fs, {
            h: [(self.pid['A'], 4), (self.pid['B'], 5), (self.pid['C'], 6)]
            for h in range(1, 19)
        })
        calculate_skins(self.fs)
        tally_spots(self.fs, 1, [{'player_id': self.pid['A'], 'count': 2}])
        tally_spots(self.fs, 5, [{'player_id': self.pid['B'], 'count': 1}])

        skins_net = {p['player_id']: p.get('net', p.get('payout', 0)) or 0
                     for p in skins_summary(self.fs)['players']}
        spots_net = {p['player_id']: p.get('net', 0) or 0
                     for p in spots_summary(self.fs)['players']}
        expected = {pid: round(skins_net.get(pid, 0) + spots_net.get(pid, 0), 2)
                    for pid in self.pid.values()}

        s = round_settlement(self.round)
        got = {p['player_id']: p['net'] for p in s['players']}
        self.assertEqual(got, expected)
        self.assertAlmostEqual(sum(got.values()), 0.0, places=2)

        # Both games are itemized.
        self.assertEqual({g['game'] for g in s['per_game']}, {'skins', 'spots'})

        # Transfers reconcile every player exactly to their net.
        by_transfer = defaultdict(float)
        for t in s['transfers']:
            by_transfer[t['from']] -= t['amount']
            by_transfer[t['to']]   += t['amount']
        for pid, net in got.items():
            self.assertAlmostEqual(by_transfer.get(pid, 0.0), net, places=2)

    def test_none_when_no_nettable_game(self):
        r = make_round(self.tee.course, active_games=['nassau'])
        make_foursome(r, [('X', 0), ('Y', 0)], tee=self.tee)
        self.assertIsNone(round_settlement(r))

    def test_match_play_places_paid_pool(self):
        """A completed Singles Bracket nets each player payout − entry fee."""
        from services.tournament_match_play import (
            setup_tournament_match_play, tournament_match_play_summary)
        rnd = make_round(self.tee.course, active_games=['match_play'])
        fs = make_foursome(
            rnd, [('A', 0), ('B', 5), ('C', 10), ('D', 15)], tee=self.tee)
        bracket = setup_tournament_match_play(
            fs, entry_fee=10.0,
            payout_config={'1st': 24, '2nd': 10, '3rd': 6, '4th': 0})

        matches = list(bracket.matches.order_by('round_number', 'id'))
        semis = [m for m in matches if m.round_number == 1]
        final, third = [m for m in matches if m.round_number == 2][:2]
        for m in semis:                    # semi winners = each match's player1
            m.result = 'player1'
            m.status = 'complete'
            m.save(update_fields=['result', 'status'])
        # Fill round 2 (what calculate would do) then decide it.
        final.player1, final.player2 = semis[0].player1, semis[1].player1
        final.result = 'player1'
        final.status = 'complete'
        final.save()
        third.player1, third.player2 = semis[0].player2, semis[1].player2
        third.result = 'player1'
        third.status = 'complete'
        third.save()
        bracket.status = 'complete'
        bracket.winner = final.player1
        bracket.save(update_fields=['status', 'winner'])

        # Sanity: summary carries player_id per payout.
        money = tournament_match_play_summary(fs)['money']
        self.assertTrue(all('player_id' in p for p in money['payouts']))

        # match_play alone is a single game → no cross-game Settlement tab now;
        # exercise the per-game net math directly.
        self.assertIsNone(round_settlement(rnd))
        nets = _pid_nets_for_game('match_play', rnd, [fs])
        self.assertEqual(nets[final.player1_id], 14.0)   # 1st: 24 − 10
        self.assertEqual(nets[final.player2_id], 0.0)    # 2nd: 10 − 10
        self.assertEqual(nets[third.player1_id], -4.0)   # 3rd:  6 − 10
        self.assertEqual(nets[third.player2_id], -10.0)  # 4th:  0 − 10
        self.assertAlmostEqual(sum(nets.values()), 0.0, places=2)

    def test_match_play_incomplete_nets_nothing(self):
        from services.tournament_match_play import setup_tournament_match_play
        rnd = make_round(self.tee.course, active_games=['match_play'])
        fs = make_foursome(
            rnd, [('A', 0), ('B', 5), ('C', 10), ('D', 15)], tee=self.tee)
        setup_tournament_match_play(fs, entry_fee=10.0,
                                    payout_config={'1st': 40})
        # Bracket still pending → no money settled yet, so no tab.
        self.assertIsNone(round_settlement(rnd))

    def test_uncovered_game_reported(self):
        # Two nettable games (skins + spots) produce a tab; a team game (nassau)
        # rides along as uncovered. (Needs 2+ nettable now that the tab is
        # cross-game only.)
        self.round.active_games = ['skins', 'spots', 'nassau']
        self.round.save(update_fields=['active_games'])
        setup_skins(self.fs)
        setup_spots(self.fs, bet_unit=Decimal('1'),
                    payout_style='per_point', per_point_mode='all')
        submit_round(self.fs, {
            1: [(self.pid['A'], 4), (self.pid['B'], 5), (self.pid['C'], 6)],
        })
        calculate_skins(self.fs)
        tally_spots(self.fs, 1, [{'player_id': self.pid['A'], 'count': 1}])
        s = round_settlement(self.round)
        self.assertIn('nassau', s['uncovered_games'])
        self.assertEqual({g['game'] for g in s['per_game']}, {'skins', 'spots'})


class FourballSixesSettlementRegressionTests(TestCase):
    """Fourball AND Sixes money.by_player entries must carry player_id, or the
    cross-game Settlement tab 500s (shipped 2.3.0 bug: KeyError 'player_id' in
    settlement._pid_nets_for_game). A team wins outright so real money moves."""

    def _round(self, game):
        tee = make_tee()
        rnd = make_round(tee.course, active_games=[game])
        rnd.bet_unit = Decimal('5.00')
        rnd.save(update_fields=['bet_unit'])
        fs = make_foursome(
            rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)], tee=tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        # Team A/B beat C/D on every hole.
        submit_round(fs, {
            h: [(pid['A'], 4), (pid['B'], 4), (pid['C'], 6), (pid['D'], 6)]
            for h in range(1, 19)
        })
        return tee, rnd, fs, pid

    def test_fourball_nets_by_player_id(self):
        # Exercise the exact crash site directly (gate-independent): the fourball
        # branch must return {player_id: net} without KeyError 'player_id'.
        from services.fourball import setup_fourball, calculate_fourball
        tee, rnd, fs, pid = self._round('fourball')
        setup_fourball(fs, [pid['A'], pid['B']], [pid['C'], pid['D']],
                       handicap_mode='gross')
        calculate_fourball(fs)

        nets = _pid_nets_for_game('fourball', rnd, [fs])   # must NOT raise
        self.assertAlmostEqual(sum(nets.values()), 0.0, places=2)
        self.assertGreater(nets[pid['A']], 0)              # winners collect
        self.assertLess(nets[pid['C']], 0)                 # losers pay

    def test_sixes_nets_by_player_id(self):
        from services.sixes import setup_sixes, calculate_sixes
        tee, rnd, fs, pid = self._round('sixes')
        base = {'team_select_method': 'long_drive',
                'team1_player_ids': [pid['A'], pid['B']],
                'team2_player_ids': [pid['C'], pid['D']]}
        setup_sixes(fs, [
            {**base, 'start_hole':  1, 'end_hole':  6},
            {**base, 'start_hole':  7, 'end_hole': 12},
            {**base, 'start_hole': 13, 'end_hole': 18},
        ], handicap_mode='gross')
        calculate_sixes(fs)

        nets = _pid_nets_for_game('sixes', rnd, [fs])      # must NOT raise
        self.assertAlmostEqual(sum(nets.values()), 0.0, places=2)
        self.assertIn(pid['A'], nets)                      # keyed by player_id


class SettlementTabGateTests(TestCase):
    """The Settlement tab is cross-game — it appears only when 2+ games settle."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['skins', 'spots'])
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round, [('A', 0), ('B', 0), ('C', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        submit_round(self.fs, {
            h: [(self.pid['A'], 4), (self.pid['B'], 5), (self.pid['C'], 6)]
            for h in range(1, 19)
        })

    def test_single_game_has_no_tab(self):
        self.round.active_games = ['skins']
        self.round.save(update_fields=['active_games'])
        setup_skins(self.fs)
        calculate_skins(self.fs)
        self.assertIsNone(round_settlement(self.round))

    def test_two_games_show_tab(self):
        setup_skins(self.fs)
        setup_spots(self.fs, bet_unit=Decimal('1'),
                    payout_style='per_point', per_point_mode='all')
        calculate_skins(self.fs)
        tally_spots(self.fs, 1, [{'player_id': self.pid['A'], 'count': 1}])
        s = round_settlement(self.round)
        self.assertIsNotNone(s)
        self.assertEqual({g['game'] for g in s['per_game']}, {'skins', 'spots'})
