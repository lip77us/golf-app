"""
scoring/tests/test_handicap_override.py
---------------------------------------
Forcing a playing handicap from an externally-managed card.

The case: a round scored in Halved but *managed* by Golf Genius, whose card
hands each golfer a PLAYING handicap that is already post-allowance. Without
this the only way to hit those numbers is to edit each golfer's index — which
changes them in every other round and on every future one — and restart the
round to see whether the guess landed.

Two properties matter and both are asserted here: the override wins over the
index, and **no allowance is applied on top of it** — the external system
already applied one, and applying Halved's as well is the double-count the
whole feature exists to avoid.
"""
from decimal import Decimal

from django.test import TestCase

from scoring.handicap import _effective_hcp, effective_hcp_for
from ._helpers import make_foursome, make_round, make_tee


class EffectiveHandicapForTests(TestCase):
    """The one function every game asks for a golfer's strokes."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs    = make_foursome(self.round, [('Paul', 12), ('Sam', 20)],
                                   tee=self.tee)
        self.m = {m.player.name: m
                  for m in self.fs.memberships.select_related('player')}

    def test_without_an_override_it_is_the_ordinary_chain(self):
        m = self.m['Paul']
        for pct in (100, 90, 75):
            self.assertEqual(effective_hcp_for(m, pct),
                             _effective_hcp(m.playing_handicap, pct))

    def test_an_override_wins_over_the_computed_handicap(self):
        m = self.m['Paul']
        m.playing_handicap_override = 17
        self.assertEqual(effective_hcp_for(m, 100), 17)

    def test_no_allowance_is_applied_on_top_of_an_override(self):
        """The card already applied one. Applying Halved's as well is the
        double-count this feature exists to prevent."""
        m = self.m['Paul']
        m.playing_handicap_override = 20
        for pct in (100, 90, 75, 50):
            self.assertEqual(effective_hcp_for(m, pct), 20,
                             f'{pct}% must not touch a forced handicap')

    def test_an_override_of_zero_is_honoured_not_treated_as_absent(self):
        """Scratch is a real answer; `if override:` would silently drop it."""
        m = self.m['Paul']
        m.playing_handicap_override = 0
        self.assertEqual(effective_hcp_for(m, 90), 0)
        self.assertNotEqual(m.playing_handicap, 0)

    def test_clearing_it_returns_the_golfer_to_a_computed_handicap(self):
        m = self.m['Paul']
        m.playing_handicap_override = 17
        self.assertEqual(effective_hcp_for(m, 100), 17)
        m.playing_handicap_override = None
        self.assertEqual(effective_hcp_for(m, 100), m.playing_handicap)

    def test_it_is_per_golfer_not_per_group(self):
        self.m['Paul'].playing_handicap_override = 9
        self.assertEqual(effective_hcp_for(self.m['Paul'], 100), 9)
        self.assertEqual(effective_hcp_for(self.m['Sam'], 100),
                         self.m['Sam'].playing_handicap)

    def test_the_roster_index_is_never_touched(self):
        """The whole point: editing the index is what this replaces, because
        it changes that golfer in every other round and every future one."""
        m = self.m['Paul']
        before = m.player.handicap_index
        m.playing_handicap_override = 30
        m.save(update_fields=['playing_handicap_override'])
        m.player.refresh_from_db()
        self.assertEqual(m.player.handicap_index, before)


class OverrideChangesStrokesTests(TestCase):
    """It has to move the dots on the card, not just a stored number."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['low_net_round'])
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(self.round, [('Paul', 4), ('Sam', 4)],
                                tee=self.tee)
        self.m = {m.player.name: m
                  for m in self.fs.memberships.select_related('player')}

    def test_two_golfers_off_the_same_index_get_different_strokes(self):
        from scoring.handicap import make_strokes_fn
        strokes = make_strokes_fn(self.fs)
        paul, sam = self.m['Paul'], self.m['Sam']
        self.assertEqual(effective_hcp_for(paul, 100),
                         effective_hcp_for(sam, 100))

        paul.playing_handicap_override = 18   # a stroke on every hole
        got = [strokes(effective_hcp_for(paul, 100), paul.tee, h)
               for h in range(1, 19)]
        self.assertEqual(got, [1] * 18)

        # Sam is untouched and still plays off his computed handicap.
        self.assertEqual(effective_hcp_for(sam, 100), sam.playing_handicap)
