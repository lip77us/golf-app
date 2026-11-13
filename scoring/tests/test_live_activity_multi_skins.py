"""
The Multi-Group Skins lock screen
(`handoff-lock-screens-mgskins-minisingles-nassaunine-solo`, section 1).

Two groups, six golfers in the pool (four in group 1, two in group 2): a hole
closes only when group 2 has posted it too.
"""
from services.live_activity_multi_skins import (multi_skins_activity_state,
                                                multi_skins_final_state)
from services.live_activity_registry import (BUILDERS, UNSHIPPED_KINDS,
                                             card_kind, holes_played,
                                             round_has_board)

from .test_multi_skins_hole_card import _PoolBase


class _Lock(_PoolBase):
    def state(self, who='Paul', fs=None):
        fs = fs or self.g1
        pid = self.pid.get(who) if who else None
        return multi_skins_activity_state(
            fs, player_id=pid, thru=holes_played(fs))


class RegistrationTests(_Lock):
    def test_its_own_kind_held_until_the_build_ships(self):
        self.assertIn('multi_skins', BUILDERS)
        self.assertEqual(card_kind('multi_skins'), 'multi_skins')
        self.assertIn('multi_skins', UNSHIPPED_KINDS)

    def test_the_shipped_gate_withholds_it(self):
        self.round.primary_game = 'multi_skins'
        self.round.active_games = ['multi_skins']
        self.assertFalse(round_has_board(self.round))


class BeforeAnyCloseTests(_Lock):
    def test_the_card_has_started_and_says_so(self):
        self._g1(1)                       # group 1 posts; group 2 has not
        c = self.state()
        self.assertEqual(c['kind'], 'multi_skins')
        self.assertEqual(c['header']['game'], 'MULTI-GROUP SKINS')
        self.assertEqual(c['header']['segment'], 'HOLE 2 · PAR 4')
        self.assertEqual(c['number'], {'text': 'NO SKINS',
                                       'colour': 'neutral'})
        self.assertEqual(c['state'], {'word': 'HOLE 1',
                                      'to_play': 'LAST GROUP ON IT'})
        self.assertEqual(c['sides'][0]['names'],
                         '0 awarded · 0 halved · 6 golfers')
        self.assertEqual(c['footer']['money'], '')
        self.assertNotIn('$', repr(c))

    def test_a_sole_low_on_an_open_hole_is_a_leader(self):
        self._g1(1, paul=3)
        self.assertEqual(self.state()['footer']['context'],
                         '1 leader on an open hole')


class RunningTests(_Lock):
    def test_the_last_hole_to_close_is_the_headline(self):
        self._g1(1, paul=3)
        self._g2(1)                       # the last group clears the 1st
        c = self.state()
        self.assertEqual(c['number']['text'], 'Paul Kelly')
        self.assertEqual(c['number']['colour'], 'mint')
        self.assertEqual(c['number']['alts'],
                         ['Paul Kelly', 'P. Kelly', 'Kelly'])
        self.assertEqual(c['state'], {'word': 'HOLE 1',
                                      'to_play': 'WON THE SKIN'})
        self.assertEqual(c['sides'][0]['names'], '1 skins awarded · 0 halved')
        self.assertEqual(c['footer']['context'], 'P. Kelly leads on 1')

    def test_a_halved_hole_takes_the_same_slot(self):
        self._g1(1, paul=3)
        self._g2(1)
        self._g1(2)
        self._g2(2)                       # everybody ties on the 2nd
        c = self.state()
        self.assertEqual(c['number'], {'text': 'HALVED',
                                       'colour': 'neutral'})
        self.assertEqual(c['state'], {'word': 'HOLE 2',
                                      'to_play': 'NO SKIN'})
        self.assertEqual(c['sides'][0]['names'], '1 skins awarded · 1 halved')

    def test_the_awarded_and_halved_add_up_to_the_holes_closed(self):
        for h in range(1, 5):
            self._g1(h, paul=3 if h % 2 else 4)
            self._g2(h)
        s = self.state()['sides'][0]['names']
        a, b = [int(x.split()[0]) for x in s.split(' · ')]
        self.assertEqual(a + b, 4)

    def test_ties_on_skins_go_to_the_most_recent_winner(self):
        self._g1(1, paul=3)
        self._g2(1)
        self._g1(2, dave=3)
        self._g2(2)
        # Paul and Dave each have one; Dave's came last.
        self.assertEqual(self.state()['footer']['context'].split(' · ')[-1],
                         'D. Moran leads on 1')

    def test_the_corner_is_the_readers_thru_and_gross(self):
        self._g1(1, paul=5)
        self._g2(1)
        self.assertTrue(self.state()['thru'].startswith('THRU 1'))

    def test_no_money_while_running(self):
        self._g1(1, paul=3)
        self._g2(1)
        self.assertNotIn('$', repr(self.state()))


class WatcherTests(_Lock):
    def test_the_two_personal_corners_change(self):
        self._g1(1, paul=3)
        self._g2(1)
        c = self.state(who=None)
        self.assertEqual(c['header']['segment'], '')
        self.assertEqual(c['header']['chip'], 'WATCHING')
        self.assertEqual(c['thru'], '6 GOLFERS')
        # Everything else is the same card.
        self.assertEqual(c['number']['text'], 'Paul Kelly')
        self.assertEqual(c['sides'], self.state()['sides'])


class FinalTests(_Lock):
    def test_round_complete_is_the_first_dollar_figure(self):
        self._g1(1, paul=3)
        self._g2(1)
        self._g1(2, dave=3)
        self._g2(2)
        for h in range(3, 19):
            self._g1(h)
            self._g2(h)
        c = multi_skins_final_state(self.g1, player_id=self.pid['Paul'])
        self.assertEqual(c['header']['segment'], 'ROUND COMPLETE')
        # $60 pool, two skins: $30 a skin.
        self.assertEqual(c['number']['text'], '$30 per skin — 2 won')
        self.assertEqual(c['sides'][0]['names'],
                         'Winners: Moran  1 · Kelly  1')
        self.assertEqual(c['footer']['context'],
                         '6 golfers · $60 pot · 16 halved')
        self.assertTrue(c['closed'])

    def test_no_skins_at_all(self):
        for h in range(1, 19):
            self._g1(h)
            self._g2(h)
        c = multi_skins_final_state(self.g1, player_id=self.pid['Paul'])
        self.assertEqual(c['number']['text'], 'No skins won')
        self.assertEqual(c['sides'], [])
