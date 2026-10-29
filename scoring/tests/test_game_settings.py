"""The settings strip: `services/game_settings.py`.

Written as pure units because the whole value of this module is that ONE
place names these rules — so what is worth pinning is the words, the order
and the refusals, none of which need a round.
"""

from django.test import SimpleTestCase

from services.game_settings import (
    attach, handicap_chip, settings_chips,
)


class HandicapChipTests(SimpleTestCase):
    def test_the_allowance_is_named_only_when_it_is_not_100(self):
        self.assertEqual(handicap_chip('net', 100), 'Net')
        self.assertEqual(handicap_chip('net', 90), 'Net 90%')
        self.assertEqual(handicap_chip('strokes_off', 80), 'Strokes off 80%')

    def test_gross_never_carries_an_allowance(self):
        """A percentage of nothing is a number that applies to nothing."""
        self.assertEqual(handicap_chip('gross', 90), 'Gross')

    def test_always_percent_states_100(self):
        """Solo's case: the allowance is the only setting the game has."""
        self.assertEqual(
            handicap_chip('net', 100, always_percent=True), 'Net 100%')

    def test_an_unknown_mode_says_nothing_rather_than_printing_a_slug(self):
        for mode in ('keep_rotating', 'amount', 'place', '', None):
            self.assertIsNone(handicap_chip(mode, 100), mode)

    def test_a_missing_allowance_still_names_the_mode(self):
        self.assertEqual(handicap_chip('net', None), 'Net')
        self.assertEqual(handicap_chip('net', 'ninety'), 'Net')


class ChipsTests(SimpleTestCase):
    def test_the_nested_handicap_block_is_read(self):
        self.assertEqual(
            settings_chips({'handicap': {'mode': 'net', 'net_percent': 90}}),
            ['Net 90%'])

    def test_the_flat_keys_are_read_too(self):
        """Both shapes are live — the newer summaries nest it, older ones do
        not — so reading one would blank half the boards."""
        self.assertEqual(
            settings_chips({'handicap_mode': 'gross'}), ['Gross'])

    def test_claremont_is_named_and_standard_is_not(self):
        base = {'handicap_mode': 'net', 'net_percent': 100}
        self.assertEqual(settings_chips({**base, 'variant': 'claremont'}),
                         ['Net', 'Claremont'])
        self.assertEqual(settings_chips({**base, 'variant': 'none'}), ['Net'])

    def test_carry_is_stated_both_ways(self):
        self.assertIn('Carries on', settings_chips({'carryover': True}))
        self.assertIn('No carry', settings_chips({'carryover': False}))

    def test_per_point_names_the_MODE_not_the_style(self):
        """`per_point` tells a golfer nothing the mode does not."""
        self.assertEqual(
            settings_chips({'payout_style': 'per_point',
                            'per_point_mode': 'first'}),
            ['Pay the leader'])

    def test_pool_is_named_from_the_style(self):
        self.assertEqual(settings_chips({'payout_style': 'pool'}), ['Pool'])

    def test_a_loss_cap_is_money_and_is_stated(self):
        self.assertEqual(settings_chips({'loss_cap': 20}),
                         ['Loses at most $20'])
        self.assertEqual(settings_chips({'loss_cap': 12.5}),
                         ['Loses at most $12.50'])

    def test_no_cap_says_nothing(self):
        for v in (None, 0, 0.0, ''):
            self.assertEqual(settings_chips({'loss_cap': v}), [], repr(v))

    def test_the_stake_is_deliberately_absent(self):
        """Its unit is game-specific — a hole, a skin, a point, a ball — so
        naming it generically would be guessing, and every board already
        carries its own money line."""
        chips = settings_chips({'bet_unit': 5, 'handicap_mode': 'net',
                                'net_percent': 100})
        self.assertEqual(chips, ['Net'])

    def test_the_order_is_fixed(self):
        """Two cards must never list the same facts in a different order —
        the summary comes off a jsonb column, which does not preserve keys."""
        full = {
            'loss_cap': 20, 'payout_style': 'pool', 'carryover': True,
            'press_mode': 'auto', 'variant': 'claremont',
            'handicap_mode': 'net', 'net_percent': 90,
        }
        self.assertEqual(settings_chips(full), [
            'Net 90%', 'Claremont', 'Auto presses', 'Carries on', 'Pool',
            'Loses at most $20',
        ])
        # Same facts, keys inserted in the opposite order.
        self.assertEqual(settings_chips(dict(reversed(list(full.items())))),
                         settings_chips(full))

    def test_an_empty_or_odd_summary_is_silent(self):
        self.assertEqual(settings_chips({}), [])
        self.assertEqual(settings_chips(None), [])
        self.assertEqual(settings_chips('nonsense'), [])


class TheMoneyBlockIsReadTests(SimpleTestCase):
    """Four of the five games with a settlement mode nest it under `money`.

    The first version read the top level only, so Points 5-3-1, Skins, Spots
    and Honors said nothing about how they settle — and a real Points round
    in the local database carried a **$6 loss cap** that no surface named.
    """

    def test_a_nested_settlement_mode_is_named(self):
        self.assertEqual(
            settings_chips({
                'handicap': {'mode': 'strokes_off', 'net_percent': 100},
                'money': {'bet_unit': 1.0, 'payout_style': 'per_point',
                          'per_point_mode': 'average'},
            }),
            ['Strokes off', 'Against the average'])

    def test_a_nested_loss_cap_is_named(self):
        """Foursome 257's own shape."""
        self.assertIn(
            'Loses at most $6',
            settings_chips({
                'handicap': {'mode': 'strokes_off', 'net_percent': 100},
                'money': {'payout_style': 'per_point',
                          'per_point_mode': 'average', 'loss_cap': 6.0},
            }))

    def test_a_nested_pool_is_named(self):
        self.assertIn('Pool',
                      settings_chips({'money': {'payout_style': 'pool'}}))

    def test_a_nested_carryover_is_named(self):
        self.assertIn('Carries on',
                      settings_chips({'money': {'carryover': True}}))

    def test_the_top_level_wins(self):
        """A game that states a key outright means it."""
        self.assertIn(
            'Pool',
            settings_chips({'payout_style': 'pool',
                            'money': {'payout_style': 'per_point',
                                      'per_point_mode': 'first'}}))

    def test_a_money_block_that_is_not_a_dict_is_ignored(self):
        self.assertEqual(settings_chips({'money': 12}), [])


class AttachTests(SimpleTestCase):
    def test_a_flat_block_gets_its_chips(self):
        games = {'skins': {'label': 'Skins', 'carryover': True,
                           'handicap_mode': 'net', 'net_percent': 100}}
        attach(games)
        self.assertEqual(games['skins']['settings'], ['Net', 'Carries on'])

    def test_an_unconfigured_block_gets_nothing(self):
        """`{label}` alone is a game that has not been set up — there are no
        settings yet, and inventing a chip would say otherwise."""
        games = {'spots': {'label': 'Spots'}}
        attach(games)
        self.assertNotIn('settings', games['spots'])

    def test_groups_that_agree_put_the_chips_on_the_block(self):
        g = {'summary': {'handicap_mode': 'net', 'net_percent': 90}}
        games = {'nassau': {'label': 'Nassau',
                            'by_group': [dict(g), dict(g)]}}
        attach(games)
        self.assertEqual(games['nassau']['settings'], ['Net 90%'])

    def test_groups_that_DISAGREE_leave_the_block_blank(self):
        """A strip at the top of a tab covering both groups would be telling
        half the field something untrue."""
        games = {'nassau': {'label': 'Nassau', 'by_group': [
            {'summary': {'handicap_mode': 'net', 'net_percent': 90}},
            {'summary': {'handicap_mode': 'gross'}},
        ]}}
        attach(games)
        self.assertNotIn('settings', games['nassau'])
        self.assertEqual(games['nassau']['by_group'][0]['settings'],
                         ['Net 90%'])
        self.assertEqual(games['nassau']['by_group'][1]['settings'], ['Gross'])

    def test_the_group_list_can_be_called_anything(self):
        """`by_group` in some games, `foursomes` in others — picking one key
        is what hid a Points 5-3-1 round from the Strokes-Off tab."""
        games = {'sixes': {'label': 'Sixes', 'foursomes': [
            {'summary': {'handicap_mode': 'strokes_off', 'net_percent': 100}},
        ]}}
        attach(games)
        self.assertEqual(games['sixes']['settings'], ['Strokes off'])

    def test_a_game_that_set_its_own_settings_is_left_alone(self):
        games = {'solo': {'label': 'Nassau', 'settings': ['Net 110%'],
                          'net_percent': 110}}
        attach(games)
        self.assertEqual(games['solo']['settings'], ['Net 110%'])

    def test_attach_is_silent_on_rubbish(self):
        games = {'x': None, 'y': 'nope', 'z': []}
        attach(games)          # must not raise
        attach(None)
