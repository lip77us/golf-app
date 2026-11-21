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


class StripsPressesAndMoneyTests(WatchClaremontTests):
    def test_the_strips_colour_the_side_that_won_the_hole(self):
        self._setup()
        self._play(1, 4, 5, 6, 7)            # Paul + Dave take both balls
        self._play(2, 6, 7, 4, 5)            # Sam + Mike take both
        self._play(3, 4, 5, 4, 5)            # halved
        html = self._page()
        self.assertEqual(html.count('class="team1">1<'), 2)   # top + bottom
        self.assertEqual(html.count('class="team2">2<'), 2)
        self.assertEqual(html.count('class="half">3<'), 2)

    def test_a_split_bottom_hole_is_plain_not_a_side(self):
        self._setup()
        # Paul wins the low ball, the second balls tie: one point, not two.
        self._play(1, 4, 6, 5, 6)
        html = self._page()
        self.assertIn('class="team1">1<', html)          # top: Paul's side
        self.assertIn('class="half">1<', html)           # bottom: split

    def test_money_each_names_every_golfer(self):
        self._setup()
        for h in range(1, 4):
            self._play(h, 4, 5, 6, 7)
        html = self._page()
        self.assertIn('Money each', html)
        for name in ('Paul', 'Dave', 'Sam', 'Mike'):
            self.assertIn(name, html)
        self.assertIn('−$', html)
        self.assertIn('+$', html)

    def test_a_called_press_is_its_own_row(self):
        self._setup()
        self._play(1, 4, 4, 6, 6)
        self._play(2, 4, 4, 6, 6)            # 2 down on top: auto press
        self.assertIn('Auto press 3–', self._page())
