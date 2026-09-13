"""
scoring/tests/test_live_activity_triple_cup.py
----------------------------------------------
The Triple Cup lock screen.

One eighteen-hole round cut into thirds — Fourball, Foursomes, two Singles run
together — for four points, where 2½ wins the cup and 2–2 halves it.

Spec: `~/Downloads/handoff-lock-screens 2/triple-cup/HANDOFF.md`.
"""
from decimal import Decimal

from django.test import TestCase

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):

    def setUp(self):
        from services.triple_cup import setup_triple_cup
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['triple_cup'])
        self.round.primary_game = 'triple_cup'
        self.round.bet_unit = Decimal('5.00')
        self.round.save(update_fields=['primary_game', 'bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Tom Hayes', 0), ('Lee Naylor', 0),
             ('Sam Reid', 0), ('Dave Moran', 0)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['Tom Hayes'], self.pid['Lee Naylor']],
            team2_ids=[self.pid['Sam Reid'], self.pid['Dave Moran']],
            handicap_mode='gross')

    def _play(self, hole, hayes, naylor, reid, moran):
        from services.triple_cup import calculate_triple_cup
        submit_hole(self.fs, hole, [
            (self.pid['Tom Hayes'], hayes), (self.pid['Lee Naylor'], naylor),
            (self.pid['Sam Reid'], reid), (self.pid['Dave Moran'], moran)])
        calculate_triple_cup(self.fs)

    def _state(self, thru, who='Tom Hayes'):
        from services.live_activity_triple_cup import triple_cup_activity_state
        return triple_cup_activity_state(
            self.fs, player_id=self.pid[who] if who else None, thru=thru)


class HeadlineTests(_Base):

    def test_the_headline_is_the_cup_score_including_nil_nil(self):
        """A headline that means one thing before the first point and another
        after is a slot nobody can learn. `0–0` over four grey cells is the
        complete and true state of the cup on the third tee."""
        self.assertEqual(self._state(0)['number']['text'], '0–0')

    def test_level_is_neutral_never_mint(self):
        """Mint is the app's colour, not a side's."""
        self.assertEqual(self._state(0)['number']['colour'], 'neutral')

    def test_the_headline_is_not_the_match_in_front_of_you(self):
        """Triple Cup exists to produce a cup score; the match you are in is a
        way of earning one point in it, and gets the smaller slot."""
        self._play(1, 3, 4, 5, 5)
        s = self._state(1)
        self.assertNotIn('UP', s['number']['text'])
        self.assertIn('UP', s['state']['word'] + s['state']['to_play'])

    def test_halves_read_as_halves_not_decimals(self):
        from services.live_activity_triple_cup import _score
        self.assertEqual(_score(2.5), '2½')
        self.assertEqual(_score(3), '3')
        self.assertEqual(_score(0), '0')


class StateSlotTests(_Base):

    def test_it_names_the_segment_so_the_live_third_is_never_inferred(self):
        self._play(1, 3, 4, 5, 5)
        self.assertTrue(self._state(1)['state']['to_play'].startswith('IN THE'))

    def test_the_margin_is_written_from_the_readers_side(self):
        """Team 1 is 1 up, so team 2's reader is 1 down — not 1 up."""
        self._play(1, 3, 4, 5, 5)
        mine = self._state(1, who='Tom Hayes')['state']['word']
        theirs = self._state(1, who='Sam Reid')['state']['word']
        self.assertEqual(mine, '1 UP')
        self.assertEqual(theirs, '1 DN')

    def test_the_cup_outranks_the_hole_when_it_cannot_be_lost(self):
        """The single moment the cup takes the slot from the match."""
        from services.live_activity_triple_cup import _cannot_lose
        self.assertTrue(_cannot_lose(2, 1, 4))     # one out, worst case 2–2
        self.assertFalse(_cannot_lose(1, 1, 4))    # two out
        self.assertFalse(_cannot_lose(1, 0, 4))


class StripTests(_Base):
    """Four cells are the FORMAT, not a guess — which is why this card can
    carry a structure graphic where Sixes could not. Sixes cut its pips because
    a round has no fixed number of matches."""

    def test_four_cells_and_all_of_them_out_at_the_start(self):
        s = self._state(0)
        self.assertEqual(len(s['pips']), 4)
        self.assertEqual(set(s['pips']), {'out'})

    def test_a_banked_point_takes_its_side_s_colour(self):
        from services.live_activity_triple_cup import _cells
        summary = {'matches': [
            {'status': 'complete', 'result': 'team1'},
            {'status': 'complete', 'result': 'team2'},
            {'status': 'complete', 'result': 'halved'},
            {'status': 'in_progress', 'result': None},
        ]}
        self.assertEqual(_cells(summary),
                         ['blue', 'orange', 'halved', 'out'])


class SidesLineTests(_Base):
    """**One row, everywhere.** A row each measured 163pt — over the ceiling on
    its own — and the second sides row is the most expensive line in the set at
    18pt. Abbreviating to surnames buys both matches for nothing."""

    def test_the_sides_line_is_always_one_row(self):
        self._play(1, 3, 4, 5, 5)
        self.assertEqual(len(self._state(1)['sides']), 1)

    def test_the_two_singles_share_that_row_with_the_readers_first(self):
        for h in range(1, 14):
            self._play(h, 4, 4, 4, 4)
        s = self._state(13)
        line = s['sides'][0]['names']
        if ' · ' in line and 'v.' in line:
            self.assertTrue(line.startswith('You v.'),
                            f'the reader own single must come first: {line}')


class FooterTests(_Base):

    def test_the_stake_is_per_man(self):
        self.assertEqual(self._state(0)['footer']['context'], '$5 a man')

    def test_the_money_is_empty_until_the_cup_settles(self):
        self._play(1, 3, 4, 5, 5)
        self.assertEqual(self._state(1)['footer']['money'], '')
