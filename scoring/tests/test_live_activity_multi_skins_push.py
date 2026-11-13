"""
The Multi-Group Skins push: a hole closing with a skin won, once, to the pool.
"""
from games.models import MultiSkinsGame
from services.live_activity_multi_skins_push import multi_skins_alerts

from .test_multi_skins_hole_card import _PoolBase


class _Push(_PoolBase):
    def alerts(self):
        return multi_skins_alerts(self.round)

    def announced(self):
        return MultiSkinsGame.objects.get(round=self.round).announced


class MultiSkinsPushTests(_Push):
    def test_first_call_baselines_without_announcing(self):
        self._g1(1, paul=3)
        self._g2(1)                          # hole 1 closed: Paul's skin
        self.assertEqual(self.alerts(), {})
        self.assertEqual(self.announced(), ['hole:1'])

    def test_a_closing_skin_rings_everyone_and_the_winner_in_second_person(self):
        self.alerts()                        # baseline
        self._g1(1, paul=3)
        self.assertEqual(self.alerts(), {})  # group 2 has not posted
        self._g2(1)
        a = self.alerts()
        self.assertEqual(set(a), set(self.pid[n] for n in self.IN_POOL))
        self.assertIn('You took the skin on 1', a[self.pid['Paul']]['body'])
        self.assertIn('Paul', a[self.pid['Larry']]['body']
                      if 'Larry' in self.IN_POOL else a[self.pid['Dave']]['body'])

    def test_it_fires_once(self):
        self.alerts()
        self._g1(1, paul=3)
        self._g2(1)
        self.assertTrue(self.alerts())
        self.assertEqual(self.alerts(), {})

    def test_a_halved_hole_does_not_ring_but_is_recorded(self):
        self.alerts()
        self._g1(1)
        self._g2(1)                          # all level: dead hole
        self.assertEqual(self.alerts(), {})
        self.assertEqual(self.announced(), ['hole:1'])

    def test_several_holes_closing_at_once_name_the_latest(self):
        self.alerts()
        self._g1(1, paul=3)
        self._g1(2, paul=3)
        self._g2(1)
        self._g2(2)
        body = self.alerts()[self.pid['Paul']]['body']
        self.assertIn('on 2', body)
