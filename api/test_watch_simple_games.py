"""
api/test_watch_simple_games.py
------------------------------
The watch page for the per-player money games — Survivor, Rabbit, Honors and
Spots.

**Ten live games rendered nothing on a watch page**, which is the link the
share card and the invite card both advertise. These four are the same shape,
so they share one renderer and one template, driven by a spec table naming
which key holds each game's figure.

**A spec table is a set of claims about somebody else's payload**, and it was
wrong the first time it ran: it named `holes_banked` for Banker, a key that
summary does not emit, and the page drew `0 banked` against every golfer on a
round that had been played out. Nothing failed — `|default:0` filled it in.
So the first test here calls every summary for real and asserts the fields the
table names actually exist.
"""
from django.test import TestCase

from api.watch_views import _SIMPLE_GAME_SPECS, _simple_group_card
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)


class SpecTableTests(TestCase):
    """The table's claims about each summary, checked against the summary."""

    def setUp(self):
        course = make_course()
        self.tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.round = make_round(course=course, active_games=[])
        self.fs = make_foursome(
            self.round, [('Ann', 4), ('Bea', 9), ('Cal', 14)], tee=self.tee)
        self.par = {h['number']: h['par'] for h in DEFAULT_HOLES}

    def _pid(self, name):
        return next(m.player_id for m in self.fs.memberships.all()
                    if m.player.name == name)

    def _setup(self, key):
        """Start the game this spec describes, however it is started."""
        import importlib
        mod = importlib.import_module(_SIMPLE_GAME_SPECS[key]['module'])
        getattr(mod, f'setup_{key}')(self.fs)

    def test_every_spec_names_fields_the_summary_actually_emits(self):
        """The Banker defect, generalised.

        A spec naming a key that does not exist fails SILENTLY — the template
        defaults it to 0 and the page looks fine while reporting nothing.
        """
        import importlib
        for key, spec in _SIMPLE_GAME_SPECS.items():
            with self.subTest(game=key):
                self._setup(key)
                submit_hole(self.fs, 1, [
                    (self._pid('Ann'), self.par[1] - 1),
                    (self._pid('Bea'), self.par[1]),
                    (self._pid('Cal'), self.par[1] + 1),
                ])
                mod = importlib.import_module(spec['module'])
                summary = getattr(mod, spec['fn'])(self.fs)
                players = summary.get('players') or []
                self.assertTrue(players, f'{key} emitted no players')
                row = players[0]
                self.assertIn(spec['figure'], row,
                              f"{key}: spec names figure `{spec['figure']}`, "
                              f"which the summary does not emit")
                self.assertIn(spec['money'], row,
                              f"{key}: spec names money `{spec['money']}`, "
                              f"which the summary does not emit")

    def test_every_spec_has_a_singular_and_a_plural(self):
        """`1 rabbits` shipped in the first render."""
        for key, spec in _SIMPLE_GAME_SPECS.items():
            with self.subTest(game=key):
                self.assertTrue(spec.get('unit'))
                self.assertTrue(spec.get('unit_one'))

    def test_banker_is_not_in_the_table(self):
        """It has no per-player COUNT — `banking` and `betting` are two halves
        of a money total — and a grid, an exposure ladder and a biggest-swings
        list this card has nowhere to put. It gets its own renderer."""
        self.assertNotIn('banker', _SIMPLE_GAME_SPECS)

    def test_the_card_maps_a_row_per_golfer(self):
        self._setup('rabbit')
        submit_hole(self.fs, 1, [
            (self._pid('Ann'), self.par[1] - 2),
            (self._pid('Bea'), self.par[1]),
            (self._pid('Cal'), self.par[1]),
        ])
        card = _simple_group_card(self.fs, _SIMPLE_GAME_SPECS['rabbit'])
        self.assertEqual(len(card['rows']), 3)
        self.assertEqual({r['name'] for r in card['rows']},
                         {'Ann', 'Bea', 'Cal'})
        for r in card['rows']:
            self.assertIsInstance(r['money'], float)

    def test_money_is_a_float_whatever_the_engine_settles_in(self):
        """Some engines settle in `Decimal`. One money column, one type."""
        self._setup('spots')
        card = _simple_group_card(self.fs, _SIMPLE_GAME_SPECS['spots'])
        for r in card['rows']:
            self.assertIsInstance(r['money'], float)


class WatchPageTests(TestCase):
    """The page itself, through the URL a watcher is actually given."""

    def setUp(self):
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.round = make_round(course=course, active_games=['rabbit'])
        self.fs = make_foursome(
            self.round, [('Ann', 4), ('Bea', 9), ('Cal', 14)], tee=tee)
        from services.rabbit import setup_rabbit
        setup_rabbit(self.fs)
        par = {h['number']: h['par'] for h in DEFAULT_HOLES}
        submit_hole(self.fs, 1, [
            (next(m.player_id for m in self.fs.memberships.all()
                  if m.player.name == 'Ann'), par[1] - 2),
            (next(m.player_id for m in self.fs.memberships.all()
                  if m.player.name == 'Bea'), par[1]),
            (next(m.player_id for m in self.fs.memberships.all()
                  if m.player.name == 'Cal'), par[1]),
        ])

    def test_the_game_gets_a_tab_and_the_tab_renders(self):
        url = f'/watch/{self.round.watch_token}/?view=rabbit'
        r = self.client.get(url)
        self.assertEqual(r.status_code, 200)
        body = r.content.decode()
        self.assertIn('Rabbit', body)
        self.assertIn('Ann', body)

    def test_a_started_game_with_no_scores_lists_the_golfers(self):
        """Names with zeroes, not a placeholder.

        A watcher who opens the link before the first tee wants to see who is
        playing. The summary already returns a row per golfer once the game is
        set up, so the card shows them on nothing rather than saying nothing.
        """
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        rnd = make_round(course=course, active_games=['rabbit'])
        fs = make_foursome(rnd, [('Dee', 4), ('Eve', 9), ('Fay', 14)], tee=tee)
        from services.rabbit import setup_rabbit
        setup_rabbit(fs)
        body = self.client.get(
            f'/watch/{rnd.watch_token}/?view=rabbit').content.decode()
        for name in ('Dee', 'Eve', 'Fay'):
            self.assertIn(name, body)

    def test_a_game_that_was_never_set_up_says_so(self):
        """`rabbit` is in `active_games` but nobody configured it, so the
        summary has no players at all. Say which game is waiting rather than
        drawing an empty card — a watcher would otherwise wonder whether the
        page is broken."""
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        rnd = make_round(course=course, active_games=['rabbit'])
        make_foursome(rnd, [('Dee', 4), ('Eve', 9), ('Fay', 14)], tee=tee)
        body = self.client.get(
            f'/watch/{rnd.watch_token}/?view=rabbit').content.decode()
        self.assertIn('No scores yet', body)

    def test_a_round_without_the_game_has_no_tab_for_it(self):
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        rnd = make_round(course=course, active_games=['skins'])
        make_foursome(rnd, [('Gus', 4), ('Hal', 9)], tee=tee)
        body = self.client.get(f'/watch/{rnd.watch_token}/').content.decode()
        self.assertNotIn('view=rabbit', body)


class EveryLiveGameHasATabTests(TestCase):
    """**The gap this work closed, stated as a rule.**

    Ten live games rendered nothing on a watch page. The page is what the
    share card and the invite card both point at, so a game without one is a
    link that opens on somebody else's round.

    Asserted against the dispatch table rather than by opening ten rounds:
    what went wrong was that nobody had written the renderer at all, and a
    missing key is exactly what that looks like.
    """

    def test_every_casual_game_the_app_can_start_has_a_view(self):
        from api.watch_views import _VIEW_DISPATCH
        # The slug each game uses in `Round.active_games`, mapped to the
        # `?view=` key that draws it. A game added to the app without a watch
        # page fails here.
        expected = {
            'skins': 'skins', 'multi_skins': 'multi_skins',
            'stableford': 'stableford', 'points_531': 'points_531',
            'nassau': 'nassau', 'triple_cup': 'triple_cup', 'wolf': 'wolf',
            'vegas': 'vegas', 'match_play': 'match_play', 'sixes': 'sixes',
            'pink_ball': 'red_ball', 'irish_rumble': 'irish_rumble',
            'low_net_round': 'low_net',
            # Added by this work.
            'survivor': 'survivor', 'rabbit': 'rabbit', 'honors': 'honors',
            'spots': 'spots', 'banker': 'banker',
            'fourball': 'fourball', 'triple_nassau': 'triple_nassau',
            'better_ball': 'better_ball', 'sequoya_threes': 'sequoya',
            'quota_nassau': 'quota_nassau',
        }
        for game, view in expected.items():
            with self.subTest(game=game):
                self.assertIn(view, _VIEW_DISPATCH,
                              f'{game} has no watch page')

    def test_foursome_play_has_one_too(self):
        """It is a tournament shape rather than a round game, so it is keyed
        off the config and not off `active_games`."""
        from api.watch_views import _VIEW_DISPATCH
        self.assertIn('team_play', _VIEW_DISPATCH)


class MoneyFormattingTests(TestCase):
    def test_a_negative_puts_the_sign_in_front_of_the_dollar(self):
        """`f'${v:g}'` prints `$-40`, which reads as a typo."""
        from api.watch_views import _signed_money
        self.assertEqual(_signed_money(-40), '−$40')
        self.assertEqual(_signed_money(40), '$40')
        self.assertEqual(_signed_money(0), '$0')

    def test_the_figure_takes_a_singular_and_tolerates_no_unit(self):
        from api.watch_views import _figure_text
        spec = {'unit': 'rabbits', 'unit_one': 'rabbit'}
        self.assertEqual(_figure_text(3, spec), '3 rabbits')
        self.assertEqual(_figure_text(1, spec), '1 rabbit')
        self.assertEqual(_figure_text(0, spec), '0 rabbits')
        # A record label has no unit at all.
        self.assertEqual(_figure_text('3-2-1', {'unit': ''}), '3-2-1')
        self.assertEqual(_figure_text(None, spec), '')
