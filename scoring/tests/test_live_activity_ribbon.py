"""
scoring/tests/test_live_activity_ribbon.py
------------------------------------------
The stroke band, on every card.

`POPPING ON HOLE 13` began as Survivor's and was picked up by Sequoya, both of
which wrote it themselves. It is a property of the FRAME — a golfer wants to
know he is stroking on the hole in front of him whatever is being scored — so
it now has one writer in `live_activity_registry` and every card sends it.

These tests are deliberately written per card rather than once over a loop:
each game allocates strokes differently, and the whole risk in the sweep is a
card reporting a stroke on a hole its own engine does not give one on. A loop
would prove the string is present; only the per-game assertion proves it is
TRUE.

The fixture is chosen so a wrong allocator is loud. Every golfer plays the
same tee, and the reader is off **2**, so he strokes on exactly two holes of
the round: SI 1 (hole 5) and SI 2 (hole 14). Hole 1 is SI 7 — so a card that
fired on the first tee would be reporting a stroke nobody gets.
"""
from django.test import TestCase

from core.models import HandicapMode, RoundStatus
from services.live_activity_registry import (full_round_strokes, hole_in_play,
                                             stroke_ribbon)
from ._helpers import make_foursome, make_round, make_tee, submit_hole

POPS   = 5       # stroke index 1
POPS_2 = 14      # stroke index 2
NO_POP = 1       # stroke index 7 — the first tee, and no stroke on it


def _teams(a, b, c, d):
    base = {'team_select_method': 'long_drive',
            'team1_player_ids': [a, b], 'team2_player_ids': [c, d]}
    return [{**base, 'start_hole': 1,  'end_hole': 6},
            {**base, 'start_hole': 7,  'end_hole': 12},
            {**base, 'start_hole': 13, 'end_hole': 18}]


class _Base(TestCase):
    """Four golfers; the reader is off 2 and strokes on holes 5 and 14."""

    GAMES = []

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        if self.GAMES:
            self.round.active_games = self.GAMES
            self.round.primary_game = self.GAMES[0]
            self.round.save(update_fields=['active_games', 'primary_game'])
        self.fs = make_foursome(
            self.round,
            [('Paul', 2), ('Dave', 0), ('Sam', 0), ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.reader = self.pid['Paul']

    def _play_through(self, n):
        """Score holes 1..n so the hole in play is n+1."""
        for h in range(1, n + 1):
            submit_hole(self.fs, h, [(p, 4) for p in self.pid.values()])


# ---------------------------------------------------------------------------
# The shared rules — written once, because they are the frame's
# ---------------------------------------------------------------------------

class SharedRuleTests(_Base):

    def test_the_band_names_the_hole_the_reader_is_about_to_play(self):
        alloc = full_round_strokes(self.fs, handicap_mode=HandicapMode.NET)
        self.assertEqual(
            stroke_ribbon(self.fs, self.reader, POPS, alloc),
            'POPPING ON HOLE 5')

    def test_a_hole_he_does_not_stroke_on_gets_nothing(self):
        alloc = full_round_strokes(self.fs, handicap_mode=HandicapMode.NET)
        self.assertEqual(stroke_ribbon(self.fs, self.reader, NO_POP, alloc), '')

    def test_a_scratch_golfer_never_pops(self):
        alloc = full_round_strokes(self.fs, handicap_mode=HandicapMode.NET)
        for hole in (POPS, POPS_2, NO_POP):
            self.assertEqual(
                stroke_ribbon(self.fs, self.pid['Dave'], hole, alloc), '')

    def test_a_watcher_gets_no_band(self):
        """He has no strokes because he is not playing. A watcher reading
        POPPING ON HOLE 5 would be reading someone else's card."""
        alloc = full_round_strokes(self.fs, handicap_mode=HandicapMode.NET)
        self.assertEqual(stroke_ribbon(self.fs, None, POPS, alloc), '')
        stranger = make_foursome(
            make_round(self.tee.course), [('Outsider', 20)], tee=self.tee)
        outsider = stranger.memberships.first().player_id
        self.assertEqual(stroke_ribbon(self.fs, outsider, POPS, alloc), '')

    def test_gross_pops_for_nobody(self):
        alloc = full_round_strokes(self.fs, handicap_mode=HandicapMode.GROSS)
        self.assertEqual(stroke_ribbon(self.fs, self.reader, POPS, alloc), '')

    def test_strokes_off_measures_against_the_group_low(self):
        """Off 2 against a scratch group is still 2 strokes, so the same two
        holes pop — but the anchor is the group's lowest playing handicap, not
        zero, which is what the engines use."""
        alloc = full_round_strokes(self.fs,
                                   handicap_mode=HandicapMode.STROKES_OFF)
        self.assertEqual(stroke_ribbon(self.fs, self.reader, POPS, alloc),
                         'POPPING ON HOLE 5')
        self.assertEqual(stroke_ribbon(self.fs, self.reader, NO_POP, alloc), '')

    # -- the hole in play ---------------------------------------------------

    def test_the_hole_in_play_is_the_one_after_the_last_finished(self):
        self.assertEqual(hole_in_play(self.fs, 0), 1)
        self.assertEqual(hole_in_play(self.fs, 4), 5)
        self.assertEqual(hole_in_play(self.fs, 17), 18)

    def test_a_finished_round_has_no_hole_in_play(self):
        """And so no band. Inventing one produced the HOLE 19 that read as a
        failed fetch on Survivor's card."""
        self.assertIsNone(hole_in_play(self.fs, 18))
        self.round.status = RoundStatus.COMPLETE
        self.round.save(update_fields=['status'])
        self.assertIsNone(hole_in_play(self.fs, 4))
        self.assertEqual(
            stroke_ribbon(self.fs, self.reader, hole_in_play(self.fs, 4),
                          full_round_strokes(self.fs,
                                             handicap_mode=HandicapMode.NET)),
            '')

    def test_a_back_nine_round_opens_on_the_tenth(self):
        """Play ORDER, not played + 1. The arithmetic form put the first band
        of a back-nine round on hole 1 — a hole nobody in that round plays."""
        rnd = make_round(self.tee.course, num_holes=9)
        rnd.starting_hole = 10
        rnd.save(update_fields=['starting_hole'])
        fs = make_foursome(rnd, [('A', 2), ('B', 0)], tee=self.tee)
        self.assertEqual(hole_in_play(fs, 0), 10)
        self.assertIsNone(hole_in_play(fs, 9))


# ---------------------------------------------------------------------------
# Per card — each against its own engine's allocation
# ---------------------------------------------------------------------------

class NassauRibbonTests(_Base):
    GAMES = ['nassau']

    def setUp(self):
        super().setUp()
        from services.nassau import setup_nassau
        setup_nassau(self.fs,
                     team1_ids=[self.pid['Paul'], self.pid['Dave']],
                     team2_ids=[self.pid['Sam'],  self.pid['Lee']],
                     handicap_mode=HandicapMode.NET)

    def _state(self, thru, who='Paul'):
        from services.live_activity_nassau import nassau_activity_state
        return nassau_activity_state(self.fs, player_id=self.pid[who],
                                     thru=thru)

    def test_the_card_carries_the_band_on_the_stroking_hole(self):
        self._play_through(4)
        self.assertEqual(self._state(4)['ribbon'], 'POPPING ON HOLE 5')

    def test_and_is_empty_on_a_hole_he_does_not_stroke_on(self):
        self.assertEqual(self._state(0)['ribbon'], '')

    def test_a_partner_off_scratch_sees_nothing(self):
        self._play_through(4)
        self.assertEqual(self._state(4, who='Dave')['ribbon'], '')


class SkinsRibbonTests(_Base):
    GAMES = ['skins']

    def setUp(self):
        super().setUp()
        from services.skins import setup_skins
        setup_skins(self.fs, handicap_mode=HandicapMode.NET)

    def _state(self, thru, who='Paul'):
        from services.live_activity_skins import skins_activity_state
        return skins_activity_state(self.fs, player_id=self.pid[who],
                                    thru=thru)

    def test_the_card_carries_the_band(self):
        """The most load-bearing band of the set: net skins turn on strokes,
        which is why par already sits in this card's header and no other's."""
        self._play_through(4)
        self.assertEqual(self._state(4)['ribbon'], 'POPPING ON HOLE 5')

    def test_the_first_tee_is_quiet(self):
        self.assertEqual(self._state(0)['ribbon'], '')


class FourballRibbonTests(_Base):
    GAMES = ['fourball']

    def setUp(self):
        super().setUp()
        from services.fourball import setup_fourball
        setup_fourball(self.fs,
                       team1_ids=[self.pid['Paul'], self.pid['Dave']],
                       team2_ids=[self.pid['Sam'],  self.pid['Lee']],
                       handicap_mode=HandicapMode.NET)

    def _state(self, thru, who='Paul'):
        from services.live_activity_match import match_activity_state
        return match_activity_state(self.fs, slug='fourball',
                                    player_id=self.pid[who], thru=thru)

    def test_the_match_card_carries_the_band(self):
        self._play_through(4)
        self.assertEqual(self._state(4)['ribbon'], 'POPPING ON HOLE 5')

    def test_the_first_tee_is_quiet(self):
        self.assertEqual(self._state(0)['ribbon'], '')


class SixesRibbonTests(_Base):
    """Sixes spreads a match's strokes over that match's own six holes, so it
    hands in its OWN allocation rather than the shared full-round one."""
    GAMES = ['sixes']

    def setUp(self):
        super().setUp()
        from services.sixes import setup_sixes
        setup_sixes(self.fs,
                    _teams(self.pid['Paul'], self.pid['Dave'],
                           self.pid['Sam'],  self.pid['Lee']),
                    handicap_mode=HandicapMode.NET)

    def _state(self, thru, who='Paul'):
        from services.live_activity import sixes_activity_state
        return sixes_activity_state(self.fs, player_id=self.pid[who],
                                    thru=thru)

    def test_the_card_carries_the_band(self):
        self._play_through(4)
        self.assertEqual(self._state(4)['ribbon'], 'POPPING ON HOLE 5')

    def test_the_first_tee_is_quiet(self):
        self.assertEqual(self._state(0)['ribbon'], '')


class RabbitRibbonTests(_Base):
    """Rabbit reads its allocation off its own summary — which is legitimate
    here and nowhere else: `rabbit_summary` walks the full play order and emits
    the allocator's number on every hole, scored or not, precisely so the
    stroke dots do not snap around as holes come in."""
    GAMES = ['rabbit']

    def setUp(self):
        super().setUp()
        from services.rabbit import setup_rabbit
        setup_rabbit(self.fs, handicap_mode=HandicapMode.NET, num_segments=1)

    def _state(self, thru, who='Paul'):
        from services.live_activity_rabbit import rabbit_activity_state
        return rabbit_activity_state(self.fs, player_id=self.pid[who],
                                     thru=thru)

    def test_the_card_carries_the_band(self):
        self._play_through(4)
        self.assertEqual(self._state(4)['ribbon'], 'POPPING ON HOLE 5')

    def test_the_first_tee_is_quiet(self):
        self.assertEqual(self._state(0)['ribbon'], '')
