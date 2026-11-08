"""
scoring/tests/test_singles_hole_card.py
----------------------------------------
`services.nassau.singles_hole_card` — the Singles Match score-entry card
(`~/Downloads/handoff-singles-match-score-entry`).

It is the Fourball card with one golfer a side, which is what the handoff
asks for, so the same Flutter tray draws both. Its worked examples are Paul
(CH 12) against Jim (CH 8): four strokes on SI 1–4, so on a par 4 / SI 3
Paul gets one.
"""
from decimal import Decimal

from django.test import TestCase

from services.nassau import (
    calculate_nassau, nassau_summary, setup_nassau, singles_hole_card,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole

HOLE = 2            # par 4, stroke index 3 — the handoff's hole


class _SinglesBase(TestCase):

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='net',
                                net_max_double_bogey=False)
        self.round.bet_unit = Decimal('20')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 12), ('Jim Diederich', 8)],
            tee=self.tee,
        )
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup(self, *, hmode='strokes_off'):
        return setup_nassau(self.fs, [self.pid['Paul']], [self.pid['Jim']],
                            handicap_mode=hmode, game_type='match_18')

    def _score(self, hole, paul, jim):
        submit_hole(self.fs, hole, [(self.pid['Paul'], paul),
                                    (self.pid['Jim'], jim)])
        calculate_nassau(self.fs, game_type='match_18')

    def _halve_the_first(self):
        """The match-play walk stops at the first unscored hole in play
        order, so a test about hole 2 has to play hole 1 — and the handoff's
        examples are all square going in, so this halves it.

        **Hole 1 is SI 7 on this card**, not SI 1, so Paul's four strokes
        (SI 1-4) do NOT fall there: equal gross is what halves it."""
        self._score(1, 4, 4)

    def _card(self, hole=HOLE):
        return singles_hole_card(self.fs, hole)


class TheHandoffsWorkedExamplesTests(_SinglesBase):

    def test_paul_gets_a_stroke_and_jim_does_not(self):
        self._setup()
        card = self._card()
        self.assertEqual((card['par'], card['stroke_index']), (4, 3))
        self.assertEqual({r['first']: r['strokes'] for r in card['players']},
                         {'Paul': 1, 'Jim': 0})
        self.assertEqual([s['sub'] for s in card['sides']],
                         ['CH 12 · 1 stroke', 'CH 8 · no stroke'])
        self.assertEqual(card['kind'], 'net')

    def test_paul_wins_with_the_stroke(self):
        # Paul 5 (net 4) v Jim 5 → Paul 1 UP.
        self._setup()
        self._halve_the_first()
        self._score(HOLE, paul=5, jim=5)
        card = self._card()
        self.assertEqual([s['best'] for s in card['sides']], [4, 5])
        self.assertEqual([s['result'] for s in card['sides']],
                         ['won', 'lost'])
        self.assertEqual(card['match']['headline'], 'Paul')
        self.assertEqual(card['match']['figure'], '1 UP')
        self.assertEqual(card['match']['state'], 'Paul 1 UP')

    def test_a_halved_hole(self):
        # Paul 5 (net 4) v Jim 4.
        self._setup()
        self._halve_the_first()
        self._score(HOLE, paul=5, jim=4)
        card = self._card()
        self.assertEqual([s['best'] for s in card['sides']], [4, 4])
        self.assertEqual([s['result'] for s in card['sides']],
                         ['halved', 'halved'])
        self.assertEqual(card['match']['headline'], 'All square')
        self.assertEqual(card['match']['figure'], 'AS')

    def test_jim_wins_and_the_money_follows(self):
        # Paul 6 (net 5) v Jim 4.
        self._setup()
        self._halve_the_first()
        self._score(HOLE, paul=6, jim=4)
        card = self._card()
        self.assertEqual(card['match']['state'], 'Jim 1 UP')
        self.assertEqual([(m['side'], m['amount']) for m in card['money']],
                         [(2, 20.0), (1, -20.0)])

    def test_no_stake_means_no_money_rows(self):
        self.round.bet_unit = Decimal('0')
        self.round.save(update_fields=['bet_unit'])
        self._setup()
        self._halve_the_first()
        self._score(HOLE, paul=6, jim=4)
        card = self._card()
        self.assertEqual(card['money'], [])
        self.assertEqual(card['stake'], 0)

    def test_there_is_no_best_ball_to_be(self):
        self._setup()
        self._halve_the_first()
        self._score(HOLE, paul=5, jim=5)
        self.assertEqual([r['counted'] for r in self._card()['players']],
                         [False, False])


class TheCloseOutTests(_SinglesBase):

    def _three_and_two(self):
        self._setup(hmode='gross')
        for h in range(1, 14):
            self._score(h, 4, 4)
        for h in (14, 15, 16):
            self._score(h, 3, 4)

    def test_the_closing_hole_wins_the_match(self):
        self._three_and_two()
        card = self._card(16)
        self.assertTrue(card['closed_out'])
        self.assertEqual(card['finished_on_hole'], 16)
        # **Singular**, which is the whole difference from Fourball's wording.
        self.assertEqual(card['match']['headline'], 'Paul wins')
        self.assertEqual(card['match']['figure'], '3&2')
        self.assertEqual(card['match']['line'],
                         'Closed out on 16. Holes 17–18 don’t count.')
        self.assertFalse(card['counts_for_card'])

    def test_a_hole_after_it_is_for_the_card_only(self):
        self._three_and_two()
        self._score(17, 5, 4)
        card = self._card(17)
        self.assertTrue(card['counts_for_card'])
        self.assertEqual(card['match']['headline'], 'Paul won')
        self.assertEqual(card['match']['line'],
                         'Closed out on 16. Scores here go on the card only.')
        self.assertEqual([s['result'] for s in card['sides']], [None, None])
        self.assertEqual({r['first']: r['gross'] for r in card['players']},
                         {'Paul': 5, 'Jim': 4})

    def test_the_strip_marks_the_dead_holes(self):
        self._three_and_two()
        strip = {s['hole']: s for s in self._card(16)['strip']}
        self.assertEqual(strip[16]['result'], 'T1')
        self.assertFalse(strip[16]['dead'])
        for h in (17, 18):
            self.assertTrue(strip[h]['dead'])
            self.assertFalse(strip[h]['played'])

    def test_a_match_decided_on_the_18th_is_not_a_close_out(self):
        """No holes stop counting, so it takes `1 UP` and not `1&0`."""
        self._setup(hmode='gross')
        for h in range(1, 18):
            self._score(h, 4, 4)
        self._score(18, 3, 4)
        card = self._card(18)
        self.assertFalse(card['closed_out'])
        self.assertEqual(card['match']['headline'], 'Paul wins')
        self.assertEqual(card['match']['figure'], '1 UP')
        self.assertEqual(card['match']['line'], 'Final after 18')
        self.assertTrue(card['round_over'])

    def test_a_level_18_is_a_push(self):
        self._setup(hmode='gross')
        for h in range(1, 19):
            self._score(h, 4, 4)
        card = self._card(18)
        self.assertEqual(card['match']['headline'], 'Match halved')
        self.assertEqual(card['match']['figure'], 'AS')
        self.assertEqual([m['amount'] for m in card['money']], [0.0, 0.0])


class TheCardIsThereBeforeTheHoleIsTests(_SinglesBase):

    def test_hole_one_of_a_fresh_round_has_a_card(self):
        self._setup()
        card = singles_hole_card(self.fs, 1)
        self.assertTrue(card)
        self.assertEqual(len(card['players']), 2)
        self.assertEqual(card['scored'], 0)
        self.assertFalse(card['hole_complete'])
        self.assertEqual([s['best'] for s in card['sides']], [None, None])
        self.assertEqual(card['match']['headline'], 'All square')

    def test_one_score_is_not_the_hole(self):
        self._setup()
        self._halve_the_first()
        submit_hole(self.fs, HOLE, [(self.pid['Paul'], 5)])
        calculate_nassau(self.fs, game_type='match_18')
        card = self._card()
        self.assertEqual(card['scored'], 1)
        self.assertFalse(card['hole_complete'])
        self.assertEqual(card['sides'][0]['best'], 4)
        self.assertIsNone(card['sides'][1]['best'])

    def test_no_game_means_no_card(self):
        self.assertEqual(singles_hole_card(self.fs, 1), {})

    def test_a_hole_outside_the_round_has_no_card(self):
        self._setup()
        self.round.num_holes = 9
        self.round.save(update_fields=['num_holes'])
        self.assertEqual(singles_hole_card(self.fs, 12), {})


class ItFollowsPlayOrderTests(_SinglesBase):

    def setUp(self):
        super().setUp()
        self.round.starting_hole = 13
        self.round.save(update_fields=['starting_hole'])

    def test_thru_and_the_next_hole_are_the_groups_own(self):
        self._setup()
        first = singles_hole_card(self.fs, 13)
        self.assertEqual(first['thru'], 1)
        self.assertEqual(first['next_hole'], 14)
        last = singles_hole_card(self.fs, 12)
        self.assertEqual(last['thru'], 18)
        self.assertIsNone(last['next_hole'])

    def test_the_strip_is_the_nine_being_PLAYED(self):
        self._setup()
        self.assertEqual(
            [s['hole'] for s in singles_hole_card(self.fs, 13)['strip']],
            [13, 14, 15, 16, 17, 18, 1, 2, 3])
        # Hole 4 is the SIXTEENTH played, so it belongs to the second nine.
        self.assertEqual(
            [s['hole'] for s in singles_hole_card(self.fs, 4)['strip']],
            [4, 5, 6, 7, 8, 9, 10, 11, 12])

    def test_three_up_on_the_18th_is_not_a_close_out_off_the_13th(self):
        """`18 - hole` says 3&0 and the play order says twelve holes left.

        This is the bug the Nassau engine had, and the reason this card
        could not simply read it — see `CloseOutFollowsPlayOrderTests`.
        """
        self._setup(hmode='gross')
        order = [13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 6,
                 7, 8, 9, 10, 11, 12]
        for h in order[:3]:
            self._score(h, 4, 5)
        for h in order[3:6]:
            self._score(h, 4, 4)
        card = singles_hole_card(self.fs, 18)
        self.assertFalse(card['closed_out'])
        self.assertEqual(card['match']['figure'], '3 UP')
        self.assertEqual(card['match']['line'], 'thru 6 · 12 to play')


class TheNamesAreSentencesTests(_SinglesBase):

    def test_one_first_name_a_side(self):
        self._setup()
        self.assertEqual([s['label'] for s in self._card(1)['sides']],
                         ['Paul', 'Jim'])

    def test_two_pauls_are_told_apart(self):
        self.fs.memberships.all().delete()
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 0), ('Paul Kelly', 0)],
            tee=self.tee, group_number=2)
        pid = {m.player.name: m.player_id
               for m in self.fs.memberships.select_related('player')}
        setup_nassau(self.fs, [pid['Paul Lipkin']], [pid['Paul Kelly']],
                     handicap_mode='gross', game_type='match_18')
        self.assertEqual(
            [s['label'] for s in singles_hole_card(self.fs, 1)['sides']],
            ['Paul L', 'Paul K'])


class ItAgreesWithTheBoardTests(_SinglesBase):

    def test_the_last_hole_matches_the_summary(self):
        self._setup(hmode='gross')
        for h in range(1, 18):
            self._score(h, 4, 4)
        self._score(18, 3, 4)
        card = singles_hole_card(self.fs, 18)
        overall = nassau_summary(self.fs, game_type='match_18')['overall']
        self.assertEqual(card['match']['margin'], abs(overall['margin']))
