"""
The Nassau Nine lock screen
(`handoff-lock-screens-mgskins-minisingles-nassaunine-solo`, section 3).
"""
from services.live_activity_registry import (BUILDERS, UNSHIPPED_KINDS,
                                             card_kind)
from services.live_activity_nassau_nine import (nassau_nine_activity_state,
                                                nassau_nine_final_state)
from services.nassau import calculate_nassau

from .test_nassau_nine_hole_card import _NineBase


class _Card(_NineBase):
    def state(self, thru=None):
        from services.live_activity_registry import holes_played
        return nassau_nine_activity_state(
            self.fs, player_id=self.pid['Paul'],
            thru=holes_played(self.fs) if thru is None else thru)


class RegistrationTests(_Card):
    def test_it_draws_the_match_card(self):
        self.assertIn('nassau_nine', BUILDERS)
        self.assertEqual(card_kind('nassau_nine'), 'match')
        self.assertNotIn('match', UNSHIPPED_KINDS)


class TheClockIsTheBetsTests(_Card):
    def test_front_nine(self):
        self._setup(press_mode='none')
        self._halve(1, 2, 3)
        self._play(4, 4, 5, 5, 5)           # Paul & Dave take the 4th
        c = self.state()
        self.assertEqual(c['kind'], 'match')
        self.assertEqual(c['header']['game'], 'NASSAU NINE')
        self.assertEqual(c['number'], {'text': '1 UP', 'colour': 'blue'})
        self.assertEqual(c['state'], {'word': '5 TO PLAY',
                                      'to_play': 'HOLES 1–9'})
        self.assertEqual([s['names'] for s in c['sides']],
                         ['Paul & Dave', 'Sam & Mike'])
        self.assertEqual(c['footer']['context'], '$10 a bet, each')
        self.assertEqual(c['footer']['money'], '−$10 to +$10')

    def test_header_carries_the_rounds_hole_not_the_bets(self):
        self._setup(press_mode='none')
        self._halve(1, 2, 3)
        self.assertTrue(self.state()['header']['segment'].startswith('HOLE 4'))

    def test_a_back_nine_game_names_its_holes(self):
        self.START = 10
        self.round.starting_hole = 10
        self.round.save(update_fields=['starting_hole'])
        self._setup(press_mode='none')
        self._halve(10, 11, 12)
        c = self.state()
        self.assertEqual(c['state'], {'word': '6 TO PLAY',
                                      'to_play': 'HOLES 10–18'})
        self.assertTrue(c['header']['segment'].startswith('HOLE 13'))

    def test_the_leader_is_first_and_the_reader_keeps_blue(self):
        self._setup(press_mode='none')
        self._play(1, 5, 5, 4, 4)           # Sam & Mike take it
        c = self.state()
        self.assertEqual([s['names'] for s in c['sides']],
                         ['Sam & Mike', 'Paul & Dave'])
        self.assertEqual(c['number'], {'text': '1 UP', 'colour': 'orange'})
        self.assertEqual([s['colour'] for s in c['sides']],
                         ['orange', 'blue'])

    def test_level_is_all_square(self):
        self._setup(press_mode='none')
        self._halve(1)
        self.assertEqual(self.state()['number'],
                         {'text': 'ALL SQ', 'colour': 'neutral'})

    def test_gross_to_par_is_in_the_corner(self):
        self._setup(press_mode='none')
        self._halve(1, 2)
        self.assertTrue(self.state()['thru'].startswith('THRU 2'))


class PressTests(_Card):
    def test_a_press_adds_a_chip_and_widens_the_range(self):
        self._setup(press_mode='auto', press_unit=10)
        self._play(1, 4, 5, 5, 5)           # Paul & Dave 1 UP
        self._play(2, 4, 5, 5, 5)           # 2 UP -> auto press on the 3rd
        c = self.state()
        self.assertEqual(c['number']['chip'], '+1 PRESS')
        self.assertEqual(c['footer']['money'], '−$20 to +$20')
        self.assertEqual(self.state(thru=0)['number'].get('chip'), '+1 PRESS')

    def test_no_press_no_chip(self):
        self._setup(press_mode='none')
        self._halve(1)
        self.assertNotIn('chip', self.state()['number'])


class OneVOneTests(_Card):
    SINGLES = True

    def test_the_same_card_one_name_a_line(self):
        self._setup(press_mode='none')
        for h in range(1, 6):
            self._play(h, 4, 4)             # a 1 v 1 has two scores a hole
        c = self.state()
        self.assertEqual([s['names'] for s in c['sides']],
                         ['Paul Lipkin', 'Sam Reid'])
        self.assertEqual(c['footer']['context'], '$10 a bet')
        self.assertEqual(c['number'], {'text': 'ALL SQ',
                                       'colour': 'neutral'})
        self.assertEqual(c['state']['word'], '4 TO PLAY')


class FinalTests(_Card):
    def test_a_nine_hole_round_ends_on_signing(self):
        self._setup(press_mode='none')
        for h in range(1, 7):
            self._play(h, 4, 5, 5, 5)       # Paul & Dave sweep
        for h in (7, 8, 9):
            self._halve(h)
        c = nassau_nine_final_state(self.fs, player_id=self.pid['Paul'])
        self.assertEqual(c['header']['segment'], 'NINE COMPLETE')
        self.assertEqual(c['number']['text'], '+$10')
        self.assertEqual(c['state']['to_play'], 'GROSS, 9 HOLES')
        self.assertTrue(c['footer']['context'].startswith(
            'Collect from Sam & Mike'))
        self.assertIn('match 6 UP', c['sides'][0]['names'])
        self.assertTrue(c['closed'])

    def test_a_loser_pays(self):
        self._setup(press_mode='none')
        for h in range(1, 10):
            self._play(h, 5, 5, 4, 4)
        c = nassau_nine_final_state(self.fs, player_id=self.pid['Paul'])
        self.assertEqual(c['number']['text'], '−$10')
        self.assertTrue(c['footer']['context'].startswith('Pay Sam & Mike'))

    def test_a_full_nassau_is_not_this_card(self):
        super(_NineBase, self)._setup()
        self.assertEqual(self.state(thru=0), {})
