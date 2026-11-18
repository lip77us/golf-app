"""api/test_player_stats.py — Your stats and the profile summary."""
from api.test_home_stats import HomeStatsTests as _Base


class PlayerStatsTests(_Base):
    def setUp(self):
        super().setUp()
        self.stats = '/api/stats/'

    # The parent's tests are about the home card; do not re-run them here.
    test_fewer_than_two_rounds_is_not_enough = None
    test_five_rounds = None
    test_money_hidden_without_a_stake = None

    def test_scoring_money_and_people(self):
        for mine in (3, 4, 4):
            self._round(mine, 5)
        d = self.c.get(self.stats).data
        self.assertEqual(d['count'], 3)
        s = d['scoring']
        self.assertIsNotNone(s['avg_gross'])
        self.assertGreater(s['birdies'], 0)
        self.assertAlmostEqual(sum(s['mix'].values()), 100, delta=0.5)
        self.assertEqual(d['money']['games'][0]['game'], 'skins')
        self.assertEqual(d['money']['games'][0]['won'], 3)
        self.assertEqual(d['people'][0]['name'], 'Pal Pal')
        self.assertEqual(d['people'][0]['rounds'], 3)
        self.assertEqual(d['courses'][0]['rounds'], 3)

    def test_unstaked_rounds_have_no_money(self):
        for _ in range(2):
            self._round(4, 5, bet='0')
        self.assertEqual(self.c.get(self.stats).data['money']['games'], [])

    def test_filters(self):
        self._round(4, 5)
        self.assertEqual(self.c.get(self.stats + '?game=nassau').data['count'], 0)
        self.assertEqual(self.c.get(self.stats + '?game=skins').data['count'], 1)

    def test_profile_summary(self):
        self._round(4, 5)
        d = self.c.get('/api/profile/summary/').data
        self.assertEqual(d['rounds'], 1)
        self.assertIsNotNone(d['since'])


class MoneyCardTests(PlayerStatsTests):
    test_scoring_money_and_people = None
    test_unstaked_rounds_have_no_money = None
    test_filters = None
    test_profile_summary = None

    def test_the_money_card_reads_the_stake_rounds_four_ways(self):
        for mine in (3, 5, 3):
            self._round(mine, 4)
        m = self.c.get(self.stats).data['money']
        self.assertEqual(len(m['series']), 3)
        self.assertEqual(m['series'][-1], m['total'])
        self.assertEqual(m['record'], {'won': 2, 'lost': 1})
        for k in ('game', 'partner', 'opponent', 'course'):
            self.assertIn(k, m['views'])
        self.assertEqual(m['views']['course'][0]['name'], 'Tilden')
        self.assertEqual(m['views']['opponent'][0]['name'], 'Pal Pal')
