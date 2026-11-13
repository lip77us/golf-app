"""
The Nassau Nine pushes: a press and the match closing out, once each, and only
to the golfers in the match.
"""
from games.models import NassauGame
from services.live_activity_nassau_nine_push import nassau_nine_alerts
from services.nassau import calculate_nassau

from .test_nassau_nine_hole_card import _NineBase


class _Push(_NineBase):
    def alerts(self):
        return nassau_nine_alerts(self.round)

    def announced(self):
        return NassauGame.objects.get(foursome=self.fs,
                                      game_type='nassau_nine').announced


class BaselineTests(_Push):
    def test_the_first_call_records_history_without_announcing_it(self):
        self._setup(press_mode='auto', press_unit=10)
        self._play(1, 4, 5, 5, 5)
        self._play(2, 4, 5, 5, 5)            # auto press already fired
        self.assertEqual(self.alerts(), {})
        self.assertIn('press:3', self.announced())

    def test_a_round_with_nothing_yet_baselines_empty(self):
        self._setup(press_mode='auto', press_unit=10)
        self.assertEqual(self.alerts(), {})
        self.assertEqual(self.announced(), [])


class PressTests(_Push):
    def _to_press(self):
        self._setup(press_mode='auto', press_unit=10)
        self._play(1, 4, 5, 5, 5)
        self.alerts()                         # baseline
        self._play(2, 4, 5, 5, 5)             # 2 UP -> auto press

    def test_an_auto_press_rings_all_four_and_names_the_trailing_side(self):
        self._to_press()
        a = self.alerts()
        self.assertEqual(set(a), set(self.pid.values()))
        paul = a[self.pid['Paul']]
        sam = a[self.pid['Sam']]
        self.assertEqual(paul['title'], 'Auto press v Sam & Mike')
        self.assertIn('Sam & Mike went 2 down on 2', paul['body'])
        self.assertIn('A new $10 bet from hole 3', paul['body'])
        self.assertEqual(sam['title'], 'Auto press v Paul & Dave')
        self.assertIn('You went 2 down on 2', sam['body'])

    def test_it_fires_once(self):
        self._to_press()
        self.assertTrue(self.alerts())
        self.assertEqual(self.alerts(), {})

    def test_a_zero_press_stake_does_not_invent_the_bets_figure(self):
        self._setup(press_mode='auto', press_unit=0)
        self._play(1, 4, 5, 5, 5)
        self.alerts()
        self._play(2, 4, 5, 5, 5)
        body = self.alerts()[self.pid['Paul']]['body']
        self.assertIn('A new press', body)
        self.assertNotIn('$', body)


class CloseOutTests(_Push):
    def test_a_close_out_names_the_margin_and_the_money(self):
        self._setup(press_mode='none')
        self._play(1, 4, 5, 5, 5)
        self.alerts()
        for h in (2, 3, 4, 5, 6, 7):
            self._play(h, 4, 5, 5, 5)         # closes 5&4 on the 5th
        a = self.alerts()
        paul = a[self.pid['Paul']]
        sam = a[self.pid['Sam']]
        self.assertEqual(paul['title'], 'Match v Sam & Mike')
        self.assertTrue(paul['body'].startswith('You won 5&4'))
        self.assertIn('+$10', paul['body'])
        self.assertTrue(sam['body'].startswith('Paul & Dave won 5&4'))
        self.assertIn('−$10', sam['body'])
        self.assertEqual(self.alerts(), {})

    def test_a_close_out_outranks_a_press_in_one_score(self):
        self._setup(press_mode='auto', press_unit=10)
        self._play(1, 4, 5, 5, 5)
        self.alerts()
        for h in range(2, 8):
            self._play(h, 4, 5, 5, 5)
        a = self.alerts()
        self.assertEqual(a[self.pid['Paul']]['title'], 'Match v Sam & Mike')
