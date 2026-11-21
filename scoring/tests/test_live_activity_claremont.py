"""
Claremont's lock screen (`handoff-claremont`, section 5): Nassau's card titled
CLAREMONT, the bottom game's points as a chip on each row, `$10 a bet`, and a
push when a press starts on its own.
"""
from games.models import NassauGame
from services.live_activity_claremont_push import claremont_alerts
from services.live_activity_nassau import (nassau_activity_state,
                                           nassau_final_state)

from .test_nassau_hole_card import _CardBase


class _Claremont(_CardBase):
    def _setup(self, **kw):
        kw.setdefault('variant', 'claremont')
        kw.setdefault('press_mode', 'auto')
        kw.setdefault('press_unit', 10)
        return super()._setup(**kw)

    def _state(self, thru, who='Paul'):
        return nassau_activity_state(self.fs, player_id=self.pid[who],
                                     thru=thru)


class CardTests(_Claremont):
    def test_it_is_titled_claremont(self):
        self._setup()
        self._play(1, 4, 5, 4, 5)
        s = self._state(1)
        self.assertEqual(s['header']['game'], 'CLAREMONT')

    def test_a_plain_nassau_is_still_nassau(self):
        super(_Claremont, self)._setup()
        self._play(1, 4, 5, 4, 5)
        self.assertTrue(self._state(1)['header']['game'].startswith('NASSAU'))
        for row in self._state(1)['rows']:
            self.assertNotIn('bottom', row)

    def test_every_row_carries_the_bottom_points(self):
        self._setup()
        # Paul + Dave take both balls on hole 1: 2 points on the bottom.
        self._play(1, 4, 5, 6, 7)
        rows = self._state(1)['rows']
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(row['bottom'], '+2 PTS')

    def test_level_reads_as_square(self):
        self._setup()
        self._play(1, 4, 5, 4, 5)
        for row in self._state(1)['rows']:
            self.assertEqual(row['bottom'], 'AS')
            self.assertEqual(row['bottom_colour'], 'neutral')

    def test_the_footer_says_a_bet_not_a_match(self):
        self._setup()
        self._play(1, 4, 5, 4, 5)
        self.assertIn('$10 a bet', self._state(1)['footer']['context'])

    def test_the_final_card_is_titled_too(self):
        self._setup()
        for h in range(1, 19):
            self._play(h, 4, 4, 5, 5)
        self.assertEqual(nassau_final_state(
            self.fs, player_id=self.pid['Paul'])['header']['game'],
            'CLAREMONT')


class PushTests(_Claremont):
    def alerts(self):
        return claremont_alerts(self.round)

    def test_the_first_call_baselines_without_announcing(self):
        self._setup()
        self._play(1, 4, 4, 6, 6)
        self._play(2, 4, 4, 6, 6)            # a press has already fired
        self.assertEqual(self.alerts(), {})
        self.assertIsNotNone(NassauGame.objects.get(
            foursome=self.fs, game_type='nassau').announced)

    def test_a_top_auto_press_rings_all_four_once(self):
        self._setup()
        self._play(1, 4, 4, 6, 6)
        self.alerts()
        self._play(2, 4, 4, 6, 6)            # 2 down on the top
        a = self.alerts()
        self.assertEqual(set(a), set(self.pid.values()))
        paul = a[self.pid['Paul']]
        self.assertEqual(paul['title'], 'Auto press')
        self.assertIn('$10 press starts on hole 3', paul['body'])
        self.assertEqual(self.alerts(), {})   # fired once

    def test_a_plain_nassau_never_rings_here(self):
        super(_Claremont, self)._setup(press_mode='auto', press_unit=10)
        self._play(1, 4, 4, 6, 6)
        self.alerts()
        self._play(2, 4, 4, 6, 6)
        self.assertEqual(self.alerts(), {})
