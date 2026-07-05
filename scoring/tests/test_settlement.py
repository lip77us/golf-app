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
from services.settlement import round_settlement
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

        s = round_settlement(rnd)
        nets = {p['player_id']: p['net'] for p in s['players']}
        self.assertEqual(nets[final.player1_id], 14.0)   # 1st: 24 − 10
        self.assertEqual(nets[final.player2_id], 0.0)    # 2nd: 10 − 10
        self.assertEqual(nets[third.player1_id], -4.0)   # 3rd:  6 − 10
        self.assertEqual(nets[third.player2_id], -10.0)  # 4th:  0 − 10
        self.assertAlmostEqual(sum(nets.values()), 0.0, places=2)
        self.assertEqual({g['game'] for g in s['per_game']}, {'match_play'})

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
        # Skins is nettable; a hypothetical team game rides along as uncovered.
        self.round.active_games = ['skins', 'nassau']
        self.round.save(update_fields=['active_games'])
        setup_skins(self.fs)
        submit_round(self.fs, {
            1: [(self.pid['A'], 4), (self.pid['B'], 5), (self.pid['C'], 6)],
        })
        calculate_skins(self.fs)
        s = round_settlement(self.round)
        self.assertIn('nassau', s['uncovered_games'])
        self.assertEqual({g['game'] for g in s['per_game']}, {'skins'})
