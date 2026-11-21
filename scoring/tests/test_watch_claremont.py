"""The Claremont watch page: the top overall as the hero with the bottom's
points under it, the two games, and the money."""
from django.test import Client

from .test_nassau_hole_card import _CardBase


class WatchClaremontTests(_CardBase):
    def _page(self):
        self.round.active_games = ['nassau']
        self.round.save(update_fields=['active_games'])
        return Client().get(
            f'/watch/{self.round.watch_token}/?view=nassau').content.decode()

    def _setup(self, **kw):
        kw.setdefault('variant', 'claremont')
        kw.setdefault('press_mode', 'auto')
        kw.setdefault('press_unit', 10)
        return super()._setup(**kw)

    def test_the_two_games_and_the_hero(self):
        self._setup()
        # Paul + Dave take both balls: 1 up on the top, 2 points on the bottom.
        self._play(1, 4, 5, 6, 7)
        html = self._page()
        self.assertIn('Claremont', html)
        self.assertIn('Top · low ball', html)
        self.assertIn('Bottom · both balls, 2 points a hole', html)
        self.assertIn('1 UP', html)
        self.assertIn('and +2 points on the bottom', html)
        self.assertIn('/games/claremont/', html)

    def test_a_plain_nassau_has_no_bottom(self):
        super(WatchClaremontTests, self)._setup()
        self._play(1, 4, 5, 6, 7)
        html = self._page()
        self.assertNotIn('Bottom · both balls', html)
        self.assertNotIn('Claremont', html)
