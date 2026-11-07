"""Group C assemblers — settle-up handoff §4.

``SETTLEMENT`` is tournament 103's real shape, copied from
``tournament_settlement`` output rather than invented: 8 golfers, one $160
Championship pot, two tied for 1st and two who won their entry back exactly.
That last pair is the case that caught two bugs.
"""
from unittest import mock

from django.test import SimpleTestCase, TestCase

from scoring.tests._helpers import _test_account, make_foursome, make_round
import services.receipt_field as rf

SETTLEMENT = {
    'golfers': [
        {'player_id': 1, 'name': 'Linda Cho', 'staked': 20.0, 'won': 40.0,
         'net': 20.0, 'entries': [{'game': 'Championship', 'amount': 20.0}],
         'prizes': [{'game': 'Championship', 'amount': 40.0,
                     'detail': '1st — Championship'}]},
        {'player_id': 2, 'name': 'Sara Lopez', 'staked': 20.0, 'won': 40.0,
         'net': 20.0, 'entries': [{'game': 'Championship', 'amount': 20.0}],
         'prizes': [{'game': 'Championship', 'amount': 40.0,
                     'detail': '1st — Championship'}]},
        {'player_id': 3, 'name': 'Mike Ross', 'staked': 20.0, 'won': 25.0,
         'net': 5.0, 'entries': [{'game': 'Championship', 'amount': 20.0}],
         'prizes': [{'game': 'Championship', 'amount': 25.0,
                     'detail': '2nd — Championship'}]},
        {'player_id': 4, 'name': 'Greg Bell', 'staked': 20.0, 'won': 20.0,
         'net': 0.0, 'entries': [{'game': 'Championship', 'amount': 20.0}],
         'prizes': [{'game': 'Championship', 'amount': 20.0,
                     'detail': '2nd — Championship'}]},
        {'player_id': 5, 'name': 'Jen Park', 'staked': 20.0, 'won': 20.0,
         'net': 0.0, 'entries': [{'game': 'Championship', 'amount': 20.0}],
         'prizes': [{'game': 'Championship', 'amount': 20.0,
                     'detail': '2nd — Championship'}]},
        {'player_id': 6, 'name': 'Dave Miller', 'staked': 20.0, 'won': 15.0,
         'net': -5.0, 'entries': [{'game': 'Championship', 'amount': 20.0}],
         'prizes': [{'game': 'Championship', 'amount': 15.0,
                     'detail': '3rd — Championship'}]},
        {'player_id': 7, 'name': 'Paul Avery', 'staked': 20.0, 'won': 0,
         'net': -20.0, 'entries': [{'game': 'Championship', 'amount': 20.0}],
         'prizes': []},
        {'player_id': 8, 'name': 'Tom Hill', 'staked': 20.0, 'won': 0,
         'net': -20.0, 'entries': [{'game': 'Championship', 'amount': 20.0}],
         'prizes': []},
    ],
    'games': [{'key': 'championship', 'label': 'Championship',
               'round_number': None, 'entries_in': 160.0, 'prizes_out': 160.0,
               'difference': 0.0, 'balanced': True,
               'transfer_in': 0.0, 'transfer_out': 0.0}],
    'balanced': True, 'blocking': [], 'can_settle': True,
    'total_collected': 45.0, 'total_paid': 45.0, 'sum_zero': True,
    'excluded_note': '',
}


class PoolRowTests(SimpleTestCase):
    """The pool is the POT, not the cash that moves."""

    def test_collected_is_what_the_field_put_in(self):
        """`total_collected` is the sum of the positive NETS — $45 on a field
        that put $160 in, because the entries were taken at signup and only
        the difference changes hands.  Labelling that "Collected" put $45
        under a row of prizes totalling $160."""
        rows = dict(rf._pool_rows(SETTLEMENT))
        self.assertEqual(rows['Collected'], '$160')
        self.assertIn('$160', rows['Paid out'])

    def test_it_says_balances_only_when_it_does(self):
        """§4's "assert that collected = paid out" holds for BOTH readings,
        which is exactly why the wrong one was not caught by it."""
        self.assertIn('balances', dict(rf._pool_rows(SETTLEMENT))['Paid out'])
        bent = {'games': [dict(SETTLEMENT['games'][0], prizes_out=100.0)]}
        self.assertNotIn('balances', dict(rf._pool_rows(bent))['Paid out'])


class PotRowTests(SimpleTestCase):

    def test_a_golfer_who_won_his_entry_back_is_still_a_winner(self):
        """Greg Bell and Jen Park net zero and won $20 each.  Building the row
        from the golfers with a non-zero net dropped them, so it totalled $120
        of a $160 pot — contradicting the pool line underneath."""
        rows = rf._pot_rows(SETTLEMENT, SETTLEMENT['golfers'])
        value = dict(rows)['Championship']
        self.assertIn('Greg Bell', value)
        self.assertIn('Jen Park', value)
        total = 40 + 40 + 25 + 20 + 20 + 15
        self.assertEqual(total, 160)


class BestFinishTests(SimpleTestCase):

    def test_the_game_comes_first_on_a_chip(self):
        """The engine writes "1st — Championship", which reads well in a list
        of one golfer's prizes.  §4's caption is "Champ. 1st": beside a name
        in a grid of four, a bare place says nothing."""
        self.assertEqual(
            rf._best_finish([{'game': 'Championship', 'amount': 40.0,
                              'detail': '1st — Championship'}]),
            'Championship 1st')

    def test_the_BEST_prize_wins_not_the_first(self):
        caption = rf._best_finish([
            {'game': 'Day bet', 'amount': 5.0, 'detail': '3rd — Day bet'},
            {'game': 'Championship', 'amount': 40.0,
             'detail': '1st — Championship'}])
        self.assertEqual(caption, 'Championship 1st')

    def test_no_prize_captions_nothing(self):
        self.assertEqual(rf._best_finish([]), '')


class CollapseTests(SimpleTestCase):

    def test_it_collapses_rather_than_truncating(self):
        rows = [{'net': n} for n in (100, 90, 80, 70, 60)]
        out = rf._collapse(rows, 3,
                           lambda tail, total: {'net': total,
                                                'name': f'{len(tail)} more'},
                           lambda tail: sum(r['net'] for r in tail))
        self.assertEqual(len(out), 4)
        self.assertEqual(out[-1]['name'], '2 more')
        self.assertEqual(out[-1]['net'], 130)
        self.assertEqual(sum(r['net'] for r in out),
                         sum(r['net'] for r in rows))

    def test_a_short_list_is_left_alone(self):
        rows = [{'net': 1}, {'net': 2}]
        self.assertEqual(rf._collapse(rows, 3, None, None), rows)


class TournamentReceiptTests(TestCase):

    def _tournament(self):
        from tournament.models import Tournament
        return Tournament.objects.create(account=_test_account(), name='T',
                                         start_date='2026-11-01')

    def _build(self, settlement):
        t = self._tournament()
        with mock.patch('services.tournament_settlement.tournament_settlement',
                        return_value=settlement):
            return t, rf.build_tournament_receipt(t)

    def test_every_golfer_is_chipped_including_the_level_ones(self):
        """§3: nets is EVERY golfer.  §2.4 spells out "$0 when level"."""
        _, receipt = self._build(SETTLEMENT)
        self.assertIsNotNone(receipt)
        self.assertEqual(len(receipt.payload['nets']), 8)
        self.assertIn(0, [n['net'] for n in receipt.payload['nets']])

    def test_the_chips_sum_to_zero(self):
        _, receipt = self._build(SETTLEMENT)
        self.assertEqual(sum(n['net'] for n in receipt.payload['nets']), 0)

    def test_the_td_pays_and_nobody_settles_peer_to_peer(self):
        """§4: entries were taken at signup, so every transfer is from the TD
        — settling between golfers would invent handovers nobody owes."""
        _, receipt = self._build(SETTLEMENT)
        froms = {t['from'] for t in receipt.payload['pays']}
        self.assertEqual(len(froms), 1)
        self.assertIn('entries taken at signup', receipt.payload['paysLabel'])

    def test_the_pays_are_ordered_by_amount(self):
        _, receipt = self._build(SETTLEMENT)
        amounts = [t['amount'] for t in receipt.payload['pays']]
        self.assertEqual(amounts, sorted(amounts, reverse=True))

    def test_the_games_row_names_a_golfer_who_won_his_entry_back(self):
        """On the BUILT receipt, not the helper.

        The bug was the call site — which golfers get passed — so a test that
        hands `_pot_rows` the full list passes with the bug in place.  Greg
        Bell and Jen Park net zero and won $20 each; without them the row
        totalled $120 of a $160 pot, contradicting the pool line under it.
        """
        _, receipt = self._build(SETTLEMENT)
        row = dict(receipt.payload['games'][0]['rows'])['Championship']
        self.assertIn('Greg Bell', row)
        self.assertIn('Jen Park', row)

    def test_the_preview_collapses_to_its_caps(self):
        """§1 caps the preview at four chips and three transfer lines."""
        _, receipt = self._build(SETTLEMENT)
        self.assertLessEqual(len(receipt.payload['imageNets']), 4)
        self.assertLessEqual(len(receipt.payload['imagePays']), 3)

    def test_provisional_money_gets_no_receipt(self):
        """The gate is the Settle gate: a receipt is treated as final by
        everyone who gets it, and a texted figure cannot be taken back."""
        _, receipt = self._build(dict(SETTLEMENT, can_settle=False))
        self.assertIsNone(receipt)

    def test_an_unbalanced_field_gets_no_receipt(self):
        """§4: "Assert that collected = paid out"."""
        _, receipt = self._build(dict(SETTLEMENT, sum_zero=False))
        self.assertIsNone(receipt)

    def test_building_twice_keeps_one_code(self):
        t, first = self._build(SETTLEMENT)
        with mock.patch('services.tournament_settlement.tournament_settlement',
                        return_value=SETTLEMENT):
            again = rf.build_tournament_receipt(t)
        self.assertEqual(again.code, first.code)

    def test_it_never_raises(self):
        t = self._tournament()
        with mock.patch('services.tournament_settlement.tournament_settlement',
                        side_effect=RuntimeError('boom')):
            self.assertIsNone(rf.build_tournament_receipt(t))


TEAM_SETTLEMENT = {
    'pool': 160.0, 'entry_fee': 20.0, 'golfers': 8, 'places_paid': 1,
    'split_pcts': [100], 'balance': 0.0, 'can_settle': True, 'waiting_on': [],
    'blocks': [{
        'places': [1], 'paying': 1, 'total': 160.0,
        'teams': [{'foursome_id': 11, 'name': 'Cho / Lopez', 'net': -6,
                   'golfers': [{'player_id': 1, 'name': 'Linda Cho',
                                'amount': 80.0},
                               {'player_id': 2, 'name': 'Sara Lopez',
                                'amount': 80.0}]}],
    }],
    'out_of_money': [
        {'foursome_id': 12, 'name': 'Ross / Bell', 'net': 2, 'rank': 2,
         'tied': False, 'per_man': -20.0, 'drive_shortfall': 0},
    ],
}


class TeamReceiptTests(TestCase):

    def _build(self, settlement):
        from tournament.models import Tournament
        t = Tournament.objects.create(account=_test_account(), name='T',
                                      start_date='2026-11-01')
        with mock.patch('services.team_play_scoring.settlement',
                        return_value=settlement):
            return t, rf.build_team_receipt(t)

    def test_the_chips_are_teams_not_golfers(self):
        """The whole difference from the tournament receipt: a team of three
        divides its share three ways and takes MORE each, so four golfer
        chips reading different figures for one prize would hide that it was
        one prize."""
        _, receipt = self._build(TEAM_SETTLEMENT)
        self.assertIsNotNone(receipt)
        names = [n['name'] for n in receipt.payload['nets']]
        self.assertIn('Cho / Lopez', names)
        self.assertNotIn('Linda Cho', names)

    def test_the_transfer_amount_is_a_string_naming_the_split(self):
        """§3 types amount as Cents | string for exactly this: the TD hands
        one team one prize, and the total would lose the per-man figure the
        golfers actually collect."""
        _, receipt = self._build(TEAM_SETTLEMENT)
        amounts = [t['amount'] for t in receipt.payload['pays']]
        self.assertEqual(amounts, ['2 \u00d7 $80'])

    def test_the_caption_carries_the_team_size(self):
        """§4: "{place} · net {n} · {k} men" — the size is why two teams can
        collect different per-man figures from one prize."""
        _, receipt = self._build(TEAM_SETTLEMENT)
        caption = receipt.payload['nets'][0]['caption']
        self.assertIn('1st', caption)
        self.assertIn('2 men', caption)

    def test_a_team_out_of_the_money_pays_its_entry(self):
        _, receipt = self._build(TEAM_SETTLEMENT)
        losing = next(n for n in receipt.payload['nets']
                      if n['name'] == 'Ross / Bell')
        self.assertEqual(losing['net'], -2000)

    def test_an_unbalanced_team_pool_gets_no_receipt(self):
        _, receipt = self._build(dict(TEAM_SETTLEMENT, balance=30.0))
        self.assertIsNone(receipt)

    def test_the_pool_section_states_the_odd_cent_rule(self):
        rows = dict(rf._team_pool_rows(
            {'entry_fee': 20, 'golfers': 8, 'pool': 160, 'blocks': []}))
        self.assertIn('Odd cents', rows)
        self.assertIn('high handicap', rows['Odd cents'])


class DispatcherTests(TestCase):

    def test_team_play_gets_the_team_document(self):
        """Its chips are teams and its transfers are one prize split several
        ways, so merging the two assemblers would make a team event read as a
        tournament whose golfers all won the same odd figure."""
        from tournament.models import Tournament
        t = Tournament.objects.create(account=_test_account(), name='T',
                                      start_date='2026-11-01')
        with mock.patch.object(rf, 'build_team_receipt') as team, \
                mock.patch.object(rf, 'build_tournament_receipt') as solo:
            with mock.patch.object(type(t), 'team_play_config',
                                   mock.PropertyMock(return_value=object()),
                                   create=True):
                rf.build_field_receipt(t)
            team.assert_called_once()
            solo.assert_not_called()


class MultiGameCasualTests(TestCase):
    """§4 C's third item, which needed no new code — step 3 already did it."""

    def _round(self):
        from services.skins import setup_skins, calculate_skins
        from services.spots import setup_spots, tally_spots
        from scoring.tests._helpers import submit_hole
        from decimal import Decimal
        rnd = make_round(active_games=['skins', 'spots'])
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        setup_skins(fs, handicap_mode='gross', carryover=False)
        setup_spots(fs, bet_unit=Decimal('1'), payout_style='pay_around')
        for hole in range(1, 19):
            scores = [(pid, 5) for pid in ids]
            if hole < 4:
                scores[0] = (ids[0], 3)
            submit_hole(fs, hole, scores)
        calculate_skins(fs)
        tally_spots(fs, 1, [{'player_id': ids[1], 'types': ['sandy']}])
        return rnd, ids

    def test_the_title_joins_the_games(self):
        from services.receipt_build import build_round_receipt
        rnd, ids = self._round()
        receipt = build_round_receipt(rnd)
        self.assertIsNotNone(receipt)
        self.assertIn(' + ', receipt.payload['title'])

    def test_there_is_one_row_per_game_and_one_settlement(self):
        """§2.2: a round playing more than one game settles ONCE, on the sum —
        otherwise the group hands money round twice for one afternoon."""
        from services.receipt_build import build_round_receipt
        rnd, ids = self._round()
        payload = build_round_receipt(rnd).payload
        rows = payload['games'][0]['rows']
        self.assertEqual(len(rows), 2)
        self.assertEqual(sum(n['net'] for n in payload['nets']), 0)
