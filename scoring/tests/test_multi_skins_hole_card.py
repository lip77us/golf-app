"""
scoring/tests/test_multi_skins_hole_card.py
-------------------------------------------
The score-entry card for a skins POOL (`multi_skins_hole_card`).

It is the Skins card's shape over the whole field, so the client draws it
with the keypad and tray it already has (Paul, 10 Nov 2026: "multi-group
skins needs the new score entry model"). What these pin is what a pool
changes: **a hole is not decided when this group finishes it**, nothing
carries, and the ledger is the field's.

Two groups. Group 1 is all in the pool; group 2 has two golfers in it and two
who are not — a golfer on a card who is not in the pool still has a score to
enter, so he still has a row.

`REGEN_POOL_FIXTURES=1 manage.py test scoring.tests.test_multi_skins_hole_card`
rewrites the JSON `mobile/test/pool_entry_test.dart` draws.
"""
import json
import os

from django.test import TestCase

from services.multi_skins import (
    calculate_multi_skins,
    multi_skins_hole_card,
    multi_skins_summary,
    setup_multi_skins,
)
from services.skins import skins_hole_card

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _PoolBase(TestCase):
    MODE = 'gross'
    G1 = [('Paul Kelly', 0), ('Dave Moran', 0), ('Sam Reid', 0),
          ('Mike Naylor', 0)]
    G2 = [('Larry Stone', 0), ('Jim Dean', 0), ('Gil Hart', 0),
          ('Wend Doman', 0)]
    IN_POOL = ('Paul', 'Dave', 'Sam', 'Mike', 'Larry', 'Jim')
    RULES = {}

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode=self.MODE,
                                net_max_double_bogey=False)
        self.g1 = make_foursome(self.round, self.G1, tee=self.tee,
                                group_number=1)
        self.g2 = make_foursome(self.round, self.G2, tee=self.tee,
                                group_number=2)
        self.pid = {}
        for fs in (self.g1, self.g2):
            for m in fs.memberships.select_related('player'):
                self.pid[m.player.name.split()[0]] = m.player_id
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid[n] for n in self.IN_POOL],
            handicap_mode=self.MODE, bet_unit=10, **self.RULES)

    def _play(self, fs, hole, **gross):
        submit_hole(fs, hole, [(self.pid[n], g) for n, g in gross.items()])
        calculate_multi_skins(self.round)

    def _g1(self, hole, paul=4, dave=4, sam=4, mike=4):
        self._play(self.g1, hole, Paul=paul, Dave=dave, Sam=sam, Mike=mike)

    def _g2(self, hole, larry=4, jim=4, gil=4, wend=4):
        self._play(self.g2, hole, Larry=larry, Jim=jim, Gil=gil, Wend=wend)

    def card(self, fs, hole):
        return multi_skins_hole_card(fs, hole)

    def row(self, card, name):
        return next(p for p in card['players']
                    if p['player_id'] == self.pid[name])


class TheCardExistsTests(_PoolBase):

    def test_a_fresh_hole_has_a_card_and_no_result(self):
        # No card means no keypad — this repo's recurring shipped-and-
        # unreachable shape — so the hole nobody has scored must have one.
        c = self.card(self.g1, 1)
        self.assertEqual(len(c['players']), 4)
        self.assertEqual(c['outcome'], 'pending')
        self.assertEqual(c['line'], '')
        self.assertFalse(c['hole_complete'])

    def test_a_round_with_no_pool_has_none(self):
        other = make_round(self.tee.course, round_number=2)
        fs = make_foursome(other, [('Solo Golfer', 0)], tee=self.tee)
        self.assertEqual(multi_skins_hole_card(fs, 1), {})

    def test_it_is_the_skins_card_s_shape(self):
        # One model and one tray on the client, so every key the Skins card
        # sends has to be here. Compared against the real thing rather than
        # a list, so a key added there fails here.
        from services.skins import setup_skins
        setup_skins(self.g1, handicap_mode='gross')
        skins = skins_hole_card(self.g1, 1)
        pool = self.card(self.g1, 1)
        # `nine` is a label the pool deliberately does not carry: a pool
        # spans groups on different nines.
        self.assertEqual(set(skins) - set(pool), {'nine'})
        self.assertEqual(set(skins['players'][0]) - set(pool['players'][0]),
                         set())

    def test_nothing_rides_and_it_says_it_is_a_pool(self):
        c = self.card(self.g1, 1)
        self.assertTrue(c['is_pool'])
        self.assertFalse(c['carry'])
        self.assertEqual((c['riding'], c['carried_in']), (1, 0))
        self.assertEqual(c['tray_trailing'], '$10 ante · $60 pool')
        self.assertEqual(c['worth_sub'], '6 in the pool · a tie kills it')

    def test_the_holes_follow_on_in_play_order(self):
        self.assertEqual(self.card(self.g1, 1)['next_hole'], 2)
        self.assertIsNone(self.card(self.g1, 18)['next_hole'])


class TheHoleWaitsForTheFieldTests(_PoolBase):
    """The ordinary state of a pool hole: this group is in, the field is not."""

    def test_this_group_in_is_not_a_result(self):
        self._g1(1, paul=3)
        c = self.card(self.g1, 1)
        self.assertTrue(c['hole_complete'])
        self.assertFalse(c['settled'])
        self.assertEqual(c['outcome'], 'waiting')
        self.assertIsNone(c['winner_id'])

    def test_it_says_who_leads_and_how_many_are_in(self):
        self._g1(1, paul=3)
        c = self.card(self.g1, 1)
        self.assertEqual(c['line'], 'Leading so far: Paul, net 3')
        self.assertEqual(c['rides_to'], '4 of 6 in')
        self.assertEqual((c['field_in'], c['field_size']), (4, 6))

    def test_a_tie_so_far_names_them(self):
        self._g1(1, paul=3, dave=3)
        self.assertEqual(self.card(self.g1, 1)['line'],
                         'Tied so far on net 3: Paul, Dave')

    def test_and_counts_them_past_what_a_line_holds(self):
        self._g1(1)
        self.assertEqual(self.card(self.g1, 1)['line'],
                         'Tied so far on net 4: 4 golfers')

    def test_nobody_is_paid_for_a_hole_still_waiting(self):
        self._g1(1, paul=3)
        c = self.card(self.g1, 1)
        self.assertTrue(all(e['money'] == 0 for e in c['ledger']))
        self.assertTrue(all(e['this_hole'] == 0 for e in c['ledger']))

    def test_the_other_group_sees_it_settle(self):
        # The same hole, from the card that completes the field.
        self._g1(1, paul=3)
        self._g2(1)
        c = self.card(self.g2, 1)
        self.assertTrue(c['settled'])
        self.assertEqual(c['outcome'], 'outright')


class TheHoleSettlesTests(_PoolBase):

    def test_a_winner_on_this_card(self):
        self._g1(1, paul=3)
        self._g2(1)
        c = self.card(self.g1, 1)
        self.assertEqual(c['outcome'], 'outright')
        self.assertEqual(c['winner_id'], self.pid['Paul'])
        self.assertEqual(c['line'], 'Paul takes the skin with net 3')
        self.assertEqual(c['rides_to'], '')

    def test_a_winner_in_another_group(self):
        self._g1(1)
        self._g2(1, larry=3)
        c = self.card(self.g1, 1)
        self.assertEqual(c['line'], 'Larry takes the skin with net 3')
        # He is not on this card, so no row on it lights up.
        self.assertNotIn(c['winner_id'],
                         [p['player_id'] for p in c['players']])

    def test_a_tie_across_groups_kills_it(self):
        self._g1(1, paul=3)
        self._g2(1, larry=3)
        c = self.card(self.g1, 1)
        self.assertEqual(c['outcome'], 'dead')
        self.assertEqual(c['line'], 'Tied on net 3: Paul, Larry')
        self.assertEqual(c['rides_to'], 'no skin')
        self.assertIsNone(c['winner_id'])

    def test_the_result_is_the_engine_s_stored_row(self):
        # Not re-derived: the card and the board must agree hole for hole.
        self._g1(1, paul=3)
        self._g2(1)
        hole = next(h for h in multi_skins_summary(self.round)['holes']
                    if h['hole'] == 1)
        self.assertEqual(self.card(self.g1, 1)['winner_id'],
                         hole['winner_id'])


class TheLedgerIsThisCardsTests(_PoolBase):
    """Paul, 10 Nov 2026: *"there could be a lot of players in the match —
    just show the status of the players in the group."*"""

    def setUp(self):
        super().setUp()
        self._g1(1)
        self._g2(1, larry=3)          # Larry takes hole 1
        self._g1(2, paul=3)           # hole 2 waits on group 2

    def test_it_lists_this_card_s_golfers_and_nobody_else(self):
        # Larry holds the pool's only skin and is in another group. He is
        # named in the result line, never given a row.
        c = self.card(self.g1, 2)
        self.assertEqual([e['first'] for e in c['ledger']],
                         ['Paul', 'Dave', 'Sam', 'Mike'])
        self.assertNotIn('other', c['ledger'][0])

    def test_and_group_two_s_card_lists_group_two(self):
        c = self.card(self.g2, 1)
        self.assertEqual([e['first'] for e in c['ledger']], ['Larry', 'Jim'])

    def test_a_golfer_holding_a_skin_leads_his_own_card(self):
        self._g2(2, jim=2)            # Jim takes hole 2 outright
        c = self.card(self.g2, 2)
        self.assertEqual([e['first'] for e in c['ledger']], ['Larry', 'Jim'])
        self._g1(3)
        self._g2(3, jim=3)            # and hole 3: Jim 2, Larry 1
        self.assertEqual([e['first'] for e in self.card(self.g2, 3)['ledger']],
                         ['Jim', 'Larry'])

    def test_colour_is_a_place_on_THIS_card(self):
        # The pool's own roster index would put group 2's golfers at 4 and
        # 5, which wrap onto group 1's colours.
        c = self.card(self.g2, 1)
        self.assertEqual(sorted(p['roster_index'] for p in c['players']),
                         [0, 1, 2, 3])
        self.assertEqual(sorted(e['roster_index'] for e in c['ledger']),
                         [0, 1])

    def test_the_money_is_the_summary_s_share(self):
        c = self.card(self.g1, 2)
        by_pid = {p['player_id']: p['payout']
                  for p in multi_skins_summary(self.round)['players']}
        for e in c['ledger']:
            self.assertEqual(e['money'], by_pid[e['player_id']])
        self.assertEqual(sum(by_pid.values()), 60)

    def test_the_footer_says_where_the_other_skins_went(self):
        # Four `$0` rows under `Won 1 of 1` would otherwise give no way to
        # see that the one went somewhere.
        c = self.card(self.g1, 2)
        self.assertEqual(
            c['footer'],
            'Won 1 of 1 settled · 1 waiting on other groups · '
            '1 to other groups')
        self.assertEqual((c['skins_won'], c['holes_played']), (1, 1))

    def test_and_says_nothing_of_them_when_this_card_holds_them_all(self):
        self.assertEqual(self.card(self.g2, 1)['footer'], 'Won 1 of 1 settled')

    def test_the_skin_won_on_this_hole_is_marked(self):
        c = self.card(self.g2, 1)
        larry = next(e for e in c['ledger'] if e['first'] == 'Larry')
        self.assertEqual(larry['this_hole'], 1)


class AGolferNotInThePoolTests(_PoolBase):
    """Gil and Wend are on group 2's card and not in the pool."""

    def test_he_has_a_row_and_no_net(self):
        self._g2(1, gil=5)
        gil = self.row(self.card(self.g2, 1), 'Gil')
        self.assertFalse(gil['in_pool'])
        self.assertEqual(gil['gross'], 5)
        self.assertIsNone(gil['net'])

    def test_his_score_still_completes_the_card(self):
        # The scorer enters four scores; the tray's title counts four.
        self._play(self.g2, 1, Larry=4, Jim=4)
        self.assertFalse(self.card(self.g2, 1)['hole_complete'])
        self._play(self.g2, 1, Gil=4, Wend=4)
        self.assertTrue(self.card(self.g2, 1)['hole_complete'])

    def test_he_never_decides_a_skin(self):
        self._g1(1)
        self._g2(1, gil=2)            # the round's low score, outside the pool
        c = self.card(self.g2, 1)
        self.assertEqual(c['outcome'], 'dead')
        self.assertNotIn('Gil', c['line'])

    def test_and_is_not_on_the_ledger(self):
        self._g2(1)
        self.assertEqual(sorted(e['first'] for e in
                                self.card(self.g2, 1)['ledger']),
                         ['Jim', 'Larry'])


class TheNetIsTheEnginesTests(_PoolBase):
    """Net mode: Dave gets a stroke a hole, and the card says so."""
    MODE = 'net'
    G1 = [('Paul Kelly', 0), ('Dave Moran', 18), ('Sam Reid', 0),
          ('Mike Naylor', 0)]

    def test_strokes_come_off_and_the_keypad_is_told(self):
        self._g1(1, dave=4)
        dave = self.row(self.card(self.g1, 1), 'Dave')
        self.assertEqual((dave['gross'], dave['strokes'], dave['net']),
                         (4, 1, 3))

    def test_strokes_are_on_the_card_before_the_hole_is_played(self):
        # The keypad reads its dots off the card, on a hole with no score.
        self.assertEqual(self.row(self.card(self.g1, 1), 'Dave')['strokes'], 1)

    def test_the_nets_run_low_to_high(self):
        self._g1(1, paul=5, dave=4, sam=6, mike=4)
        self.assertEqual([p['net'] for p in self.card(self.g1, 1)['players']],
                         [3, 4, 5, 6])


class TheGrossBirdieStealTests(_PoolBase):
    MODE = 'net'
    G1 = [('Paul Kelly', 0), ('Dave Moran', 18), ('Sam Reid', 0),
          ('Mike Naylor', 0)]
    RULES = {'birdie_steal': True}

    def test_a_natural_birdie_beats_a_made_one(self):
        self._g1(1, paul=3, dave=4)   # Paul gross 3; Dave net 3
        self._g2(1)
        c = self.card(self.g1, 1)
        self.assertEqual(c['outcome'], 'steal')
        self.assertEqual(c['steal_by'], self.pid['Paul'])
        self.assertEqual(c['line'], "Gross birdie steals. Paul's gross 3 "
                                    "beats Dave's net 3")
        self.assertTrue(self.row(c, 'Paul')['birdie'])


class PoolFixtureRegenTests(_PoolBase):
    """Writes the JSON the Dart tray tests draw — real engine output."""

    def _write(self, name, card):
        if os.environ.get('REGEN_POOL_FIXTURES') != '1':
            return
        path = os.path.join(os.path.dirname(__file__), '..', '..', 'mobile',
                            'test', 'fixtures', f'{name}.json')
        with open(path, 'w') as f:
            json.dump(card, f, indent=1, sort_keys=True)

    def test_regenerate_a_hole_waiting_on_the_field(self):
        self._g1(1)
        self._g2(1, larry=3)
        self._g1(2, paul=3, sam=5)
        card = self.card(self.g1, 2)
        self.assertEqual(card['outcome'], 'waiting')
        self._write('pool_hole2_waiting', card)

    def test_regenerate_a_hole_won_on_this_card(self):
        self._g1(1, paul=3, sam=5)
        self._g2(1)
        card = self.card(self.g1, 1)
        self.assertEqual(card['outcome'], 'outright')
        self._write('pool_hole1_won', card)

    def test_regenerate_a_hole_won_in_another_group(self):
        self._g1(1, sam=5)
        self._g2(1, larry=3)
        card = self.card(self.g1, 1)
        self.assertEqual(card['outcome'], 'outright')
        self._write('pool_hole1_won_elsewhere', card)

    def test_regenerate_a_card_with_golfers_outside_the_pool(self):
        self._g1(1)
        self._g2(1, larry=3, gil=5)
        card = self.card(self.g2, 1)
        self.assertFalse(self.row(card, 'Gil')['in_pool'])
        self._write('pool_hole1_mixed_card', card)
