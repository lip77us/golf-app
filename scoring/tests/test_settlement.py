"""
scoring/tests/test_settlement.py
--------------------------------
Cross-game settlement: round_settlement sums each game's signed per-player
net into one zero-sum "who owes whom" summary.
"""
from collections import defaultdict
from decimal import Decimal

from django.test import TestCase

from core.models import RoundStatus

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


class CasualReceiptTests(TestCase):
    """The casual receipt (services/settlement_receipt.py).

    A different document from the tournament one: no pot, no TD holding money.
    Four golfers settle among themselves, so the sentence that matters is not
    the net but "Ben owes you $12" — and the transfers are what belong in the
    group thread.
    """

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['skins'])
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_skins(self.fs)
        submit_round(self.fs, {
            h: [(self.pid['Ann'], 4), (self.pid['Ben'], 5), (self.pid['Cal'], 6)]
            for h in range(1, 19)})
        calculate_skins(self.fs)

    def _payload(self, **kw):
        from services.settlement_receipt import casual_receipt_payload
        return casual_receipt_payload(self.round, **kw)

    def _close(self):
        # RoundStatus.COMPLETE is 'complete'.  This used to say 'completed',
        # which is not a value the enum has — Django doesn't validate choices
        # on save(), so the bogus string stored happily and the gate silently
        # never opened.  Use the enum, so a rename breaks the test loudly.
        self.round.status = RoundStatus.COMPLETE
        self.round.save(update_fields=['status'])

    # -- it reads settlement, and says who pays whom -------------------------

    def test_it_reads_settlement_rather_than_recomputing(self):
        from services.settlement import round_settlement
        settled = round_settlement(self.round, min_games=1)
        self.assertEqual([g['net'] for g in self._payload()['golfers']],
                         [p['net'] for p in settled['players']])

    def test_each_golfer_gets_his_side_of_every_transfer_he_is_in(self):
        """'Ben pays you $6' and 'You pay Ann $6' are the same transfer."""
        golfers = {g['name']: g for g in self._payload()['golfers']}
        ann = golfers['Ann']
        self.assertTrue(ann['transfers'])
        self.assertTrue(all(t['owes_me'] for t in ann['transfers']),
                        'the winner is owed, never owing')
        ben = golfers['Ben']
        self.assertTrue(all(not t['owes_me'] for t in ben['transfers']))

    def test_the_personal_message_gives_the_instruction_not_the_arithmetic(self):
        self._close()
        msg = {g['name']: g['message'] for g in self._payload()['golfers']}['Ben']
        self.assertIn('Settle up', msg)
        self.assertIn('You pay', msg)

    def test_the_field_summary_carries_the_payments(self):
        """Four people in one thread need the list of payments, not each
        other's itemisation."""
        msg = self._payload()['field_summary']['message']
        self.assertIn('Settle up', msg)
        self.assertIn('pays', msg)

    def test_lines_are_per_game(self):
        """What a casual golfer disputes is the game, not an entry."""
        for g in self._payload()['golfers']:
            for line in g['games']:
                self.assertTrue(line['label'])
                self.assertNotEqual(line['amount'], 0)

    def test_the_event_name_says_where_and_when(self):
        """A receipt headed 'Round 412' tells the reader nothing."""
        self.assertIn(self.tee.course.name, self._payload()['event_name'])

    def test_the_note_reaches_both_payloads(self):
        p = self._payload(note='Venmo @paul-lipkin')
        self.assertIn('Venmo @paul-lipkin', p['field_summary']['message'])
        self.assertIn('Venmo @paul-lipkin', p['golfers'][0]['message'])

    # -- the gate ------------------------------------------------------------

    def test_an_unfinished_round_cannot_be_texted(self):
        p = self._payload()
        self.assertFalse(p['can_send'])
        self.assertTrue(any('not finished' in b for b in p['blocking']))

    def test_a_finished_round_can(self):
        self._close()
        p = self._payload()
        self.assertTrue(p['can_send'])
        self.assertEqual(p['blocking'], [])

    # -- nothing to settle ---------------------------------------------------

    def test_a_round_with_no_money_has_no_receipt(self):
        """Inventing an empty one would be worse than saying so."""
        bare = make_round(self.tee.course, active_games=[])
        make_foursome(bare, [('X', 0), ('Y', 0)], tee=self.tee)
        self.assertIsNone(self._payload_for(bare))

    def _payload_for(self, round_obj):
        from services.settlement_receipt import casual_receipt_payload
        return casual_receipt_payload(round_obj)

    def test_games_that_cannot_be_netted_are_named(self):
        """The omission would otherwise read as a bug."""
        self.round.active_games = ['skins', 'nassau']
        self.round.save(update_fields=['active_games'])
        note = self._payload()['excluded_note']
        self.assertIn('nassau', note)

    def test_a_round_that_settles_to_nothing_has_no_receipt(self):
        """A game can run and pay nobody. "+$0 to collect" is not a smaller
        receipt, it is a wrong one — and four of them is a wrong group text."""
        square = make_round(self.tee.course, active_games=['skins'])
        square.bet_unit = Decimal('1.00')
        square.save(update_fields=['bet_unit'])
        fs = make_foursome(square, [('P', 0), ('Q', 0)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_skins(fs)
        # Every hole halved: skins runs, carries to the end, pays nobody.
        submit_round(fs, {h: [(pid['P'], 4), (pid['Q'], 4)]
                          for h in range(1, 19)})
        calculate_skins(fs)
        self.assertIsNone(self._payload_for(square))

    # -- the sends, which are not one fact -----------------------------------

    def test_the_group_stamp_and_a_golfers_own_stamp_are_separate(self):
        """Texting Ben his receipt says nothing about the group thread, and a
        stamp that conflates them tells the sender he has done something he
        has not."""
        from tournament.models import SettlementSend
        self._close()
        ben = self.pid['Ben']
        SettlementSend.objects.create(round=self.round, recipients=1,
                                      mode=SettlementSend.MODE_PERSONAL,
                                      player_id=ben)
        p = self._payload()
        self.assertIsNone(p['field_summary']['last_send'],
                          'the group has not been texted')
        stamped = {g['player_id']: g['last_send'] for g in p['golfers']}
        self.assertIsNotNone(stamped[ben])
        self.assertIsNone(stamped[self.pid['Ann']],
                          "Ann's receipt has not gone")

    def test_a_field_send_does_not_stamp_any_golfer(self):
        from tournament.models import SettlementSend
        self._close()
        SettlementSend.objects.create(round=self.round, recipients=3,
                                      mode=SettlementSend.MODE_FIELD)
        p = self._payload()
        self.assertIsNotNone(p['field_summary']['last_send'])
        self.assertTrue(all(g['last_send'] is None for g in p['golfers']))

    # -- the field summary has to name people apart --------------------------

    def test_a_shared_surname_falls_back_to_the_full_name(self):
        """A family four-ball is a real casual round, and four identical
        surnames is not a shorter receipt, it is an unreadable one."""
        from services.settlement_receipt import compose_casual_field
        msg = compose_casual_field(
            event_name='Tilden', transfers=[], players=[
                {'player_id': 1, 'name': 'Paul Lipkin', 'net': 12.0},
                {'player_id': 2, 'name': 'Ryan Lipkin', 'net': -4.0},
                {'player_id': 3, 'name': 'Dana Wu',     'net': -8.0},
            ])
        self.assertIn('Paul Lipkin +$12', msg)
        self.assertIn('Ryan Lipkin -$4', msg)
        # The unambiguous one keeps the short label — one repeated surname
        # must not lengthen every line.
        self.assertIn('Wu -$8', msg)
        self.assertNotIn('Dana Wu', msg)


class MinGamesTests(TestCase):
    """The 2+ games rule belongs to the Settlement TAB, not to the money.

    A one-game round still owes somebody something — the tab just has nothing
    to add over that game's own tab. The receipt asks for min_games=1.
    """

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['skins'])
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_skins(self.fs)
        submit_round(self.fs, {
            h: [(self.pid['Ann'], 4), (self.pid['Ben'], 5), (self.pid['Cal'], 6)]
            for h in range(1, 19)})
        calculate_skins(self.fs)

    def test_the_tab_still_needs_two_games(self):
        """Unchanged default — a one-game round gets no Settlement tab."""
        self.assertIsNone(round_settlement(self.round))

    def test_one_game_still_settles_when_asked(self):
        s = round_settlement(self.round, min_games=1)
        self.assertIsNotNone(s)
        self.assertEqual(len(s['per_game']), 1)
        self.assertTrue(s['transfers'])
        self.assertAlmostEqual(sum(p['net'] for p in s['players']), 0, places=2)
