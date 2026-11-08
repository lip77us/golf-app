"""
scoring/tests/test_fourball_hole_card.py
-----------------------------------------
`services.fourball.fourball_hole_card` — the Fourball score-entry card
(`~/Downloads/handoff-fourball-score-entry`).

The handoff's worked examples are played through the REAL engine. Its group
is Paul (CH 12) and Larry (CH 14) against Jim (CH 10) and Ryan (CH 6), off
the low ball — so on its hole 5 (par 4, SI 7) only Larry gets a stroke, which
is the allocation a hand-written fixture would quietly lose.
"""
from decimal import Decimal

from django.test import TestCase

from services.fourball import (
    calculate_fourball, fourball_hole_card, setup_fourball,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole

HOLE = 1            # par 4, stroke index 7 — the handoff's hole


class _CardBase(TestCase):

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['fourball'])
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 12), ('Larry Sanders', 14),
             ('Jim Diederich', 10), ('Ryan Lipkin', 6)],
            tee=self.tee,
        )
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup(self, *, hmode='strokes_off', bet=None):
        self.game = setup_fourball(
            self.fs,
            [self.pid['Paul'], self.pid['Larry']],
            [self.pid['Jim'], self.pid['Ryan']],
            handicap_mode=hmode, net_percent=100, bet_amount=bet)
        return self.game

    def _score(self, hole, paul, larry, jim, ryan):
        submit_hole(self.fs, hole, [(self.pid['Paul'], paul),
                                    (self.pid['Larry'], larry),
                                    (self.pid['Jim'], jim),
                                    (self.pid['Ryan'], ryan)])
        calculate_fourball(self.fs)

    def _card(self, hole=HOLE):
        return fourball_hole_card(self.fs, hole)


class TheHandoffsWorkedExamplesTests(_CardBase):
    """Its hole 5 is par 4 / SI 7; this card's hole 1 is the same shape."""

    def test_only_larry_strokes(self):
        self._setup()
        card = self._card()
        self.assertEqual((card['par'], card['stroke_index']), (4, 7))
        self.assertEqual({r['first']: r['strokes'] for r in card['players']},
                         {'Paul': 0, 'Larry': 1, 'Jim': 0, 'Ryan': 0})

    def test_pine_wins_the_hole(self):
        # Paul 4, Larry 5 (net 4) v Jim 5, Ryan 5 → 4 v 5.
        self._setup()
        self._score(HOLE, paul=4, larry=5, jim=5, ryan=5)
        card = self._card()
        self.assertEqual([s['best'] for s in card['sides']], [4, 5])
        self.assertEqual([s['result'] for s in card['sides']],
                         ['won', 'lost'])
        self.assertEqual(card['match']['figure'], '1 UP')
        self.assertEqual(card['match']['headline'], 'Paul + Larry')

    def test_both_balls_can_count(self):
        # Paul's 4 and Larry's net 4 tie for the side's best, so the card
        # names both — which is why `counts` is a list.
        self._setup()
        self._score(HOLE, paul=4, larry=5, jim=5, ryan=5)
        card = self._card()
        self.assertEqual(card['sides'][0]['sub'], 'counts: Paul · Larry')
        self.assertEqual(card['sides'][1]['sub'], 'counts: Jim · Ryan')
        self.assertEqual(card['kind'], 'best ball')
        counted = {r['first'] for r in card['players'] if r['counted']}
        self.assertEqual(counted, {'Paul', 'Larry', 'Jim', 'Ryan'})

    def test_one_ball_counts(self):
        self._setup()
        self._score(HOLE, paul=4, larry=6, jim=5, ryan=7)
        card = self._card()
        self.assertEqual(card['sides'][0]['sub'], 'counts: Paul')
        self.assertEqual(card['sides'][1]['sub'], 'counts: Jim')

    def test_a_halved_hole(self):
        # Paul 5, Larry 5 (net 4) v Jim 4, Ryan 5 → 4 v 4.
        self._setup()
        self._score(HOLE, paul=5, larry=5, jim=4, ryan=5)
        card = self._card()
        self.assertEqual([s['best'] for s in card['sides']], [4, 4])
        self.assertEqual([s['result'] for s in card['sides']],
                         ['halved', 'halved'])
        self.assertEqual(card['match']['headline'], 'All square')
        self.assertEqual(card['match']['figure'], 'AS')
        self.assertEqual(card['sides'][0]['sub'], 'counts: Larry')

    def test_clay_wins_and_the_money_follows(self):
        self._setup(bet=Decimal('20'))
        self._score(HOLE, paul=5, larry=6, jim=4, ryan=6)
        card = self._card()
        self.assertEqual(card['match']['state'], 'Jim + Ryan 1 UP')
        self.assertEqual([(m['side'], m['amount']) for m in card['money']],
                         [(2, 20.0), (1, -20.0)])

    def test_no_stake_means_no_money_rows(self):
        # `bet_amount=None` inherits the ROUND's stake, which is the app's
        # own default and not the handoff's; 0 is how a group says no stake.
        self._setup(bet=Decimal('0'))
        self._score(HOLE, paul=5, larry=6, jim=4, ryan=6)
        self.assertEqual(self._card()['money'], [])
        self.assertEqual(self._card()['stake'], 0)


class TheCloseOutTests(_CardBase):
    """3 UP with 2 to play is 3&2, and the holes after it stop counting."""

    def _three_and_two(self):
        self._setup(hmode='gross', bet=Decimal('20'))
        for h in range(1, 14):                 # 13 halves
            self._score(h, 4, 4, 4, 4)
        for h in (14, 15, 16):                 # pine take three
            self._score(h, 3, 4, 4, 4)

    def test_the_closing_hole_says_the_match_is_won(self):
        self._three_and_two()
        card = self._card(16)
        self.assertTrue(card['closed_out'])
        self.assertEqual(card['finished_on_hole'], 16)
        self.assertEqual(card['match']['headline'], 'Paul + Larry win')
        self.assertEqual(card['match']['figure'], '3&2')
        self.assertEqual(card['match']['line'],
                         'Closed out on 16. Holes 17–18 don’t count.')
        self.assertTrue(card['match']['is_final'])
        # It still counts — the close-out happens ON it.
        self.assertFalse(card['counts_for_card'])
        self.assertEqual([s['result'] for s in card['sides']],
                         ['won', 'lost'])

    def test_a_hole_after_it_is_for_the_card_only(self):
        self._three_and_two()
        self._score(17, 5, 5, 4, 5)
        card = self._card(17)
        self.assertTrue(card['counts_for_card'])
        self.assertEqual(card['match']['headline'], 'Paul + Larry won')
        self.assertEqual(card['match']['line'],
                         'Closed out on 16. Scores here go on the card only.')
        # No team score at all, so no ball counted.
        self.assertEqual([s['result'] for s in card['sides']], [None, None])
        self.assertEqual([r['counted'] for r in card['players']],
                         [False, False, False, False])
        # The golfers' own figures still land.
        self.assertEqual({r['first']: r['gross'] for r in card['players']},
                         {'Paul': 5, 'Larry': 5, 'Jim': 4, 'Ryan': 5})

    def test_the_money_is_final_from_the_closing_hole(self):
        self._three_and_two()
        for h in (16, 17):
            if h == 17:
                self._score(17, 5, 5, 4, 5)
            card = self._card(h)
            self.assertEqual([(m['side'], m['amount']) for m in card['money']],
                             [(1, 20.0), (2, -20.0)])

    def test_the_strip_marks_the_dead_holes(self):
        self._three_and_two()
        card = self._card(16)
        strip = {s['hole']: s for s in card['strip']}
        self.assertEqual(sorted(strip), list(range(10, 19)))
        self.assertEqual(strip[16]['result'], 'T1')
        self.assertTrue(strip[16]['played'])
        self.assertFalse(strip[16]['dead'])
        for h in (17, 18):
            self.assertTrue(strip[h]['dead'])
            self.assertFalse(strip[h]['played'])

    def test_editing_an_earlier_hole_undoes_it(self):
        """The handoff's own case: the later holes then count again."""
        self._three_and_two()
        self._score(16, 5, 5, 4, 4)            # clay take 16 instead
        card = self._card(16)
        self.assertFalse(card['closed_out'])
        self.assertFalse(card['counts_for_card'])
        self.assertEqual(card['match']['figure'], '1 UP')


class TheMatchCardTests(_CardBase):
    def test_hole_18_states_the_final(self):
        self._setup(hmode='gross')
        for h in range(1, 18):
            self._score(h, 4, 4, 4, 4)
        self._score(18, 3, 4, 4, 4)
        card = self._card(18)
        self.assertEqual(card['match']['headline'], 'Paul + Larry win')
        self.assertEqual(card['match']['figure'], '1 UP')
        self.assertEqual(card['match']['line'], 'Final after 18')
        self.assertTrue(card['round_over'])

    def test_a_level_18_is_a_push(self):
        self._setup(hmode='gross', bet=Decimal('20'))
        for h in range(1, 19):
            self._score(h, 4, 4, 4, 4)
        card = self._card(18)
        self.assertEqual(card['match']['headline'], 'Match halved')
        self.assertEqual(card['match']['figure'], 'AS')
        self.assertEqual(card['match']['line'],
                         'Level after 18 · a push')
        self.assertEqual([m['amount'] for m in card['money']], [0.0, 0.0])

    def test_a_live_hole_counts_what_is_left(self):
        self._setup(hmode='gross')
        for h in (1, 2, 3, 4):
            self._score(h, 4, 4, 4, 4)
        self._score(5, 3, 4, 4, 4)
        card = self._card(5)
        self.assertEqual(card['match']['line'], 'thru 5 · 13 to play')

    def test_a_part_scored_hole_reports_the_standing_coming_into_it(self):
        self._setup(hmode='gross')
        self._score(1, 3, 4, 4, 4)             # pine 1 up
        submit_hole(self.fs, 2, [(self.pid['Paul'], 4)])
        calculate_fourball(self.fs)
        card = self._card(2)
        self.assertFalse(card['hole_complete'])
        self.assertEqual(card['scored'], 1)
        self.assertEqual(card['match']['figure'], '1 UP')


class TheCardIsThereBeforeTheHoleIsTests(_CardBase):
    def test_hole_one_of_a_fresh_round_has_a_card(self):
        self._setup()
        card = self._card(1)
        self.assertTrue(card)
        self.assertEqual(len(card['players']), 4)
        self.assertFalse(card['hole_complete'])
        self.assertEqual(card['scored'], 0)
        self.assertEqual([s['best'] for s in card['sides']], [None, None])
        self.assertEqual(card['match']['headline'], 'All square')

    def test_a_side_s_best_forms_as_its_two_scores_land(self):
        self._setup()
        submit_hole(self.fs, HOLE, [(self.pid['Paul'], 4)])
        calculate_fourball(self.fs)
        card = self._card()
        self.assertEqual(card['sides'][0]['best'], 4)
        self.assertIsNone(card['sides'][1]['best'])
        self.assertEqual(card['scored'], 1)

    def test_no_game_means_no_card(self):
        self.assertEqual(fourball_hole_card(self.fs, 1), {})

    def test_a_hole_outside_the_round_has_no_card(self):
        self._setup()
        self.round.num_holes = 9
        self.round.save(update_fields=['num_holes'])
        self.assertEqual(fourball_hole_card(self.fs, 12), {})


class ItFollowsPlayOrderTests(_CardBase):
    def setUp(self):
        super().setUp()
        self.round.starting_hole = 7
        self.round.save(update_fields=['starting_hole'])

    def test_thru_and_the_next_hole_are_the_groups_own(self):
        self._setup()
        first = fourball_hole_card(self.fs, 7)
        self.assertEqual(first['thru'], 1)
        self.assertEqual(first['next_hole'], 8)
        last = fourball_hole_card(self.fs, 6)
        self.assertEqual(last['thru'], 18)
        self.assertIsNone(last['next_hole'])

    def test_the_strip_is_the_nine_being_PLAYED(self):
        # Off the 7th the first nine played is 7..15, not 1..9.
        self._setup()
        self.assertEqual([s['hole'] for s in fourball_hole_card(self.fs, 7)['strip']],
                         [7, 8, 9, 10, 11, 12, 13, 14, 15])
        self.assertEqual([s['hole'] for s in fourball_hole_card(self.fs, 16)['strip']],
                         [16, 17, 18, 1, 2, 3, 4, 5, 6])
        # **Hole 1 is the 13th hole played**, so it belongs to the SECOND
        # nine — which is the case a hole-number split gets wrong while
        # agreeing on every other hole of this round.
        self.assertEqual([s['hole'] for s in fourball_hole_card(self.fs, 1)['strip']],
                         [16, 17, 18, 1, 2, 3, 4, 5, 6])

    def test_the_close_out_counts_holes_left_in_PLAY_order(self):
        # 3 up with 2 of the group's own holes left is 3&2 whatever the hole
        # numbers are: off the 7th that is on hole 4.
        self._setup(hmode='gross')
        order = [7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 6]
        for h in order[:13]:
            self._score(h, 4, 4, 4, 4)
        for h in order[13:16]:
            self._score(h, 3, 4, 4, 4)
        card = fourball_hole_card(self.fs, order[15])
        self.assertEqual(card['match']['figure'], '3&2')
        self.assertEqual(card['finished_on_hole'], 4)


class TheNamesAreSentencesTests(_CardBase):
    def test_a_side_is_named_by_first_names(self):
        self._setup()
        self.assertEqual([s['label'] for s in self._card(1)['sides']],
                         ['Paul + Larry', 'Jim + Ryan'])

    def test_two_ryans_are_told_apart(self):
        self.fs.memberships.all().delete()
        self.fs = make_foursome(
            self.round,
            [('Ryan Lipkin', 0), ('Larry Sanders', 0),
             ('Ryan Doman', 0), ('Jim Diederich', 0)],
            tee=self.tee, group_number=2)
        pid = {m.player.name: m.player_id
               for m in self.fs.memberships.select_related('player')}
        setup_fourball(self.fs,
                       [pid['Ryan Lipkin'], pid['Larry Sanders']],
                       [pid['Ryan Doman'], pid['Jim Diederich']],
                       handicap_mode='gross')
        self.assertEqual(
            [s['label'] for s in fourball_hole_card(self.fs, 1)['sides']],
            ['Ryan L + Larry', 'Ryan D + Jim'])
