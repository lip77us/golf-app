"""
scoring/tests/test_vegas_hole_card.py
-------------------------------------
`services.vegas.vegas_hole_card` — the Las Vegas score-entry card
(`~/Downloads/handoff-vegas-score-entry`).

The handoff's five worked examples are played through the REAL engine rather
than asserted against numbers typed here, because the whole point of the card
is that it renders the engine and decides nothing. Its hole is par 4 / SI 5
with the group off the low man, so Dave (4 under the low man) takes no stroke
on it while Sam (7) and Lee (10) each take one — the handoff's own
allocation, and the thing a hand-written fixture would quietly lose.

It also answers the three rules the handoff asks to confirm. Two agree with
what it drew; **the both-birdie case does not**, and that is recorded rather
than papered over.
"""
from decimal import Decimal

from django.test import TestCase

from services.vegas import calculate_vegas, setup_vegas, vegas_hole_card

from ._helpers import make_foursome, make_round, make_tee, submit_hole

HOLE = 9            # par 4, stroke index 5 — the handoff's hole


class _VegasCardBase(TestCase):
    """Paul 8 + Dave 12 against Sam 15 + Lee 18, off the low man, 25¢."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['vegas'])
        self.round.bet_unit = Decimal('0.25')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 8), ('Dave Kim', 12),
             ('Sam Reid', 15), ('Lee Nash', 18)],
            tee=self.tee,
        )
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup(self, *, gross=False, **kw):
        # `gross` for the tests whose subject is the walk rather than the
        # allocation: net == gross, so the digits are the scores entered.
        kw.setdefault('handicap_mode', 'gross' if gross else 'strokes_off')
        kw.setdefault('net_percent', 100)
        # Off the low man, and a blow-up must reach the 9 cap rather than
        # being clipped to a net double bogey first.
        kw.setdefault('net_max_double_bogey', False)
        self.game = setup_vegas(
            self.fs,
            [self.pid['Paul'], self.pid['Dave']],
            [self.pid['Sam'], self.pid['Lee']],
            **kw)
        return self.game

    def _score(self, hole, paul, dave, sam, lee):
        submit_hole(self.fs, hole, [(self.pid['Paul'], paul),
                                    (self.pid['Dave'], dave),
                                    (self.pid['Sam'],  sam),
                                    (self.pid['Lee'],  lee)])
        calculate_vegas(self.fs)

    def _card(self, hole=HOLE):
        return vegas_hole_card(self.fs, hole)

    def _nums(self, card):
        return [s['number'] for s in card['sides']]


class TheHandoffsWorkedExamplesTests(_VegasCardBase):
    """Hole 9, par 4, SI 5, 25¢ a point."""

    def test_the_strokes_are_the_handoffs(self):
        self._setup()
        card = self._card()
        self.assertEqual(card['par'], 4)
        self.assertEqual(card['stroke_index'], 5)
        self.assertEqual({r['first']: r['strokes'] for r in card['players']},
                         {'Paul': 0, 'Dave': 0, 'Sam': 1, 'Lee': 1})

    def test_an_ordinary_hole_is_45_against_57(self):
        self._setup()
        self._score(HOLE, paul=4, dave=5, sam=6, lee=8)
        card = self._card()
        self.assertEqual(self._nums(card), [45, 57])
        self.assertEqual([s['nets'] for s in card['sides']], [[4, 5], [5, 7]])
        self.assertEqual(card['winner'], 'team1')
        self.assertEqual(card['points'], 12)
        self.assertEqual([s['result'] for s in card['sides']],
                         ['won', 'lost'])

    def test_a_birdie_flips_the_other_number(self):
        # Paul makes 3 on a par 4. 35 against nets 5 and 6, which flips.
        self._setup()
        self._score(HOLE, paul=3, dave=5, sam=6, lee=7)
        card = self._card()
        self.assertEqual(self._nums(card), [35, 65])
        side2 = card['sides'][1]
        self.assertTrue(side2['flipped'])
        self.assertEqual(side2['raw'], 56,
                         'the card shows what it was before the flip')
        self.assertFalse(card['sides'][0]['flipped'])
        self.assertEqual(card['points'], 30)

    def test_a_net_of_ten_counts_nine(self):
        # Lee makes 11 for a net 10 — 49, not 410.
        self._setup()
        self._score(HOLE, paul=4, dave=5, sam=5, lee=11)
        card = self._card()
        self.assertEqual(self._nums(card), [45, 49])
        self.assertTrue(card['sides'][1]['capped'])
        self.assertFalse(card['sides'][0]['capped'])
        self.assertEqual(card['points'], 4)

    def test_a_tie_with_carry_on_doubles_the_next_hole(self):
        self._setup(carryover=True)
        self._score(HOLE, paul=4, dave=6, sam=5, lee=7)
        card = self._card()
        self.assertEqual(self._nums(card), [46, 46])
        self.assertEqual(card['winner'], 'halved')
        self.assertEqual(card['points'], 0)
        self.assertEqual(card['tie_note'], 'hole 10 doubles')
        self.assertEqual([s['result'] for s in card['sides']],
                         ['tied', 'tied'])

    def test_a_tie_with_carry_off_is_worth_nothing(self):
        self._setup(carryover=False)
        self._score(HOLE, paul=4, dave=6, sam=5, lee=7)
        self.assertEqual(self._card()['tie_note'], 'no points')

    def test_only_the_stroking_golfer_moves_the_number(self):
        # The handoff's hole 18 is SI 10, where Sam (7 off the low man) takes
        # no stroke and Lee (10) does: 45 against nets 6 and 5.  Hole 10 is
        # this card's SI 8, the same shape.
        self._setup()
        self._score(10, paul=4, dave=5, sam=6, lee=6)
        card = self._card(10)
        self.assertEqual({r['first']: r['strokes'] for r in card['players']},
                         {'Paul': 0, 'Dave': 0, 'Sam': 0, 'Lee': 1})
        self.assertEqual(self._nums(card), [45, 56])
        self.assertEqual(card['points'], 11)

    def test_the_last_hole_turns_the_tray_into_round_over(self):
        self._setup(gross=True)
        # Nothing under par anywhere — a 4 on one of this card's par 5s is a
        # birdie, and a flip would make the arithmetic below a guess.
        for h in range(1, 19):
            self._score(h, 6, 7, 8, 9)        # 67 v 89, by 22 a hole
        card = self._card(18)
        self.assertTrue(card['round_over'])
        box = card['winner_box']
        self.assertEqual(box['side'], 1)
        self.assertEqual(box['points'], 22 * 18)
        self.assertEqual(box['money'], round(22 * 18 * 0.25, 2))
        self.assertEqual(box['stake'], 0.25)
        self.assertFalse(box['level'])

    def test_the_money_is_the_margin_times_the_stake(self):
        self._setup()
        self._score(HOLE, paul=4, dave=5, sam=6, lee=8)       # +12
        card = self._card()
        money = {s['side']: s['money'] for s in card['standing']}
        self.assertEqual(money, {1: 3.0, 2: -3.0})            # 12 × 25¢
        self.assertEqual(round(sum(money.values()), 2), 0)


class TheThreeRulesTheHandoffAsksAboutTests(_VegasCardBase):
    """Its own "to confirm with the engine" list, answered."""

    def test_birdies_on_both_sides_do_NOT_cancel(self):
        """**A real divergence from the handoff's prose**, recorded here
        rather than silently resolved either way.

        It says "if both sides make a birdie, nothing flips". The engine
        applies each birdie's flip to the OPPOSING number independently, so
        both flip — and the two readings are different money, not a wash:
        here 35 v 65 is a margin of 30 where cancelling leaves 53 v 56, a
        margin of 3.
        """
        self._setup()
        # Paul 3 (birdie) and Sam 3 (net 2, a gross birdie too).
        self._score(HOLE, paul=3, dave=5, sam=3, lee=6)
        card = self._card()
        s1, s2 = card['sides']
        self.assertTrue(s1['flipped'])
        self.assertTrue(s2['flipped'])
        self.assertEqual(s1['raw'], 35)
        self.assertEqual(s1['number'], 53)
        self.assertEqual(s2['raw'], 25)
        self.assertEqual(s2['number'], 52)

    def test_carries_stack(self):
        self._setup(gross=True, carryover=True)
        self._score(1, 4, 6, 4, 6)      # 46 v 46 — tied
        self.assertEqual(vegas_hole_card(self.fs, 1)['tie_note'],
                         'hole 2 doubles')
        self._score(2, 4, 6, 4, 6)      # tied again
        self.assertEqual(vegas_hole_card(self.fs, 2)['tie_note'],
                         'hole 3 pays ×3')
        # Hole 3 is a par 3, so a 3 is par and nothing flips: 34 v 56, by 22,
        # at ×3.
        self._score(3, 3, 4, 5, 6)
        card = vegas_hole_card(self.fs, 3)
        self.assertEqual(card['points'], 66)
        self.assertEqual(card['note'], '×3 carried')

    def test_the_nine_cap_is_applied_before_the_flip(self):
        # Sam's side nets 4 and 10 → capped to 49, and Paul's birdie then
        # flips THAT, to 94. A flip before the cap would give 104 → nonsense.
        self._setup()
        self._score(HOLE, paul=3, dave=5, sam=5, lee=11)
        card = self._card()
        s2 = card['sides'][1]
        self.assertTrue(s2['capped'])
        self.assertTrue(s2['flipped'])
        self.assertEqual(s2['raw'], 49)
        self.assertEqual(s2['number'], 94)


class TheCardIsThereBeforeTheHoleIsTests(_VegasCardBase):
    """No card means no keypad — the failure Points, Rabbit, Sixes and Wolf
    each hit by gating on the game's STATUS."""

    def test_hole_one_of_a_fresh_round_has_a_card(self):
        self._setup()
        card = vegas_hole_card(self.fs, 1)
        self.assertTrue(card)
        self.assertEqual(len(card['players']), 4)
        self.assertFalse(card['hole_complete'])
        self.assertEqual(self._nums(card), [None, None])

    def test_a_side_s_number_forms_as_its_two_scores_land(self):
        """The golfer card's header tag, which is the live half of this game
        — you watch the number build."""
        self._setup()
        submit_hole(self.fs, HOLE, [(self.pid['Paul'], 4)])
        calculate_vegas(self.fs)
        self.assertIsNone(self._card()['sides'][0]['raw'])
        submit_hole(self.fs, HOLE, [(self.pid['Dave'], 5)])
        calculate_vegas(self.fs)
        card = self._card()
        self.assertEqual(card['sides'][0]['raw'], 45)
        self.assertEqual(card['sides'][0]['number'], 45)
        self.assertIsNone(card['sides'][1]['raw'])
        self.assertFalse(card['hole_complete'])

    def test_no_game_means_no_card(self):
        self.assertEqual(vegas_hole_card(self.fs, 1), {})

    def test_a_hole_outside_the_round_has_no_card(self):
        self._setup()
        self.round.num_holes = 9
        self.round.save(update_fields=['num_holes'])
        self.assertEqual(vegas_hole_card(self.fs, 12), {})


class TheStandingIsThroughThisHoleTests(_VegasCardBase):
    def test_the_figures_stop_at_the_hole_asked_for(self):
        self._setup(gross=True)
        for h in (1, 2, 3):
            self._score(h, 4, 5, 6, 8)          # 45 v 68 → +23 a hole
        card = vegas_hole_card(self.fs, 2)
        self.assertEqual(card['thru'], 2)
        self.assertEqual(card['margin_before'], 23)
        self.assertEqual(card['margin_after'], 46)
        self.assertEqual({s['side']: s['points'] for s in card['standing']},
                         {1: 46, 2: -46})
        # …and the round's own totals are a DIFFERENT set of numbers, which
        # is what makes the assertion above worth making.
        self.assertEqual(vegas_hole_card(self.fs, 3)['margin_after'], 69)

    def test_the_last_hole_agrees_with_the_board(self):
        from services.vegas import vegas_summary
        self._setup(gross=True)
        for h in range(1, 19):
            self._score(h, 4, 5, 6, 8)
        card = vegas_hole_card(self.fs, 18)
        board = {t['team_number']: (t['points'], t['money'])
                 for t in vegas_summary(self.fs)['teams']}
        self.assertEqual(card['standing'][0]['money'], board[1][1])
        self.assertEqual(card['standing'][0]['points'],
                         board[1][0] - board[2][0])

    def test_the_leading_side_is_first(self):
        self._setup(gross=True)
        self._score(HOLE, paul=6, dave=8, sam=4, lee=4)      # side 2 wins
        card = self._card()
        self.assertEqual(card['standing'][0]['side'], 2)
        # …but THE NUMBERS keep side order, so they read with the card above.
        self.assertEqual([s['side'] for s in card['sides']], [1, 2])


class TheMoneyIsTheGamesOwnTests(_VegasCardBase):
    def test_a_loss_cap_clips_the_tray_too(self):
        self._setup(loss_cap=Decimal('2'))
        self._score(HOLE, paul=4, dave=5, sam=6, lee=8)      # +12 → $3
        money = {s['side']: s['money'] for s in self._card()['standing']}
        self.assertEqual(money, {1: 2.0, 2: -2.0})
        self.assertEqual(round(sum(money.values()), 2), 0)

    def test_without_one_it_is_the_plain_arithmetic(self):
        self._setup()
        self._score(HOLE, paul=4, dave=5, sam=6, lee=8)
        money = {s['side']: s['money'] for s in self._card()['standing']}
        self.assertEqual(money, {1: 3.0, 2: -3.0})


class ItFollowsPlayOrderTests(_VegasCardBase):
    def setUp(self):
        super().setUp()
        self.round.starting_hole = 7
        self.round.save(update_fields=['starting_hole'])

    def test_thru_and_the_next_hole_are_the_groups_own(self):
        self._setup()
        first = vegas_hole_card(self.fs, 7)
        self.assertEqual(first['thru'], 1)
        self.assertEqual(first['next_hole'], 8)
        last = vegas_hole_card(self.fs, 6)
        self.assertEqual(last['thru'], 18)
        self.assertIsNone(last['next_hole'])

    def test_a_tie_on_the_18th_carries_into_the_1st(self):
        self._setup(gross=True, carryover=True)
        self._score(18, 4, 6, 4, 6)
        self.assertEqual(vegas_hole_card(self.fs, 18)['tie_note'],
                         'hole 1 doubles')

    def test_hole_18_is_not_the_end_of_a_shotgun_round(self):
        self._setup()
        card = vegas_hole_card(self.fs, 18)
        self.assertEqual(card['next_hole'], 1)
        self.assertFalse(card['round_over'])


class TheNamesAreSentencesTests(_VegasCardBase):
    def test_a_side_is_named_by_first_names(self):
        self._setup()
        card = vegas_hole_card(self.fs, 1)
        self.assertEqual([s['label'] for s in card['sides']],
                         ['Paul + Dave', 'Sam + Lee'])

    def test_a_side_reads_in_the_order_the_card_lists_it(self):
        """`VegasTeam.players` is a many-to-many with no ordering, so the
        database decides — and in these fixtures it usually agrees with
        membership order by luck, which is what makes a test over the
        ordinary roster worthless here (the Sixes anchor's lesson: a test
        whose inputs are pks cannot pin anything about pk order).

        So the membership order is built DELIBERATELY against the pks.
        """
        from ._helpers import make_player
        self.fs.memberships.all().delete()
        pl = {n: make_player(n, 0) for n in ('Alf', 'Bea', 'Cal', 'Dot')}
        # Memberships in reverse creation order, so the two disagree.
        self.fs = make_foursome(
            self.round,
            [(pl['Dot'], 0), (pl['Cal'], 0), (pl['Bea'], 0), (pl['Alf'], 0)],
            tee=self.tee, group_number=3)
        setup_vegas(self.fs, [pl['Alf'].id, pl['Dot'].id],
                    [pl['Bea'].id, pl['Cal'].id], handicap_mode='gross')
        card = vegas_hole_card(self.fs, 1)
        self.assertEqual([s['label'] for s in card['sides']],
                         ['Dot + Alf', 'Cal + Bea'])
        self.assertEqual([r['first'] for r in card['players']],
                         ['Dot', 'Alf', 'Cal', 'Bea'])

    def test_two_daves_are_told_apart(self):
        self.fs.memberships.all().delete()
        self.fs = make_foursome(
            self.round,
            [('Dave Kim', 0), ('Dave Moran', 0), ('Sam Reid', 0),
             ('Lee Nash', 0)],
            tee=self.tee, group_number=2,
        )
        pid = {m.player.name: m.player_id
               for m in self.fs.memberships.select_related('player')}
        setup_vegas(self.fs, [pid['Dave Kim'], pid['Sam Reid']],
                    [pid['Dave Moran'], pid['Lee Nash']],
                    handicap_mode='gross')
        card = vegas_hole_card(self.fs, 1)
        self.assertEqual([s['label'] for s in card['sides']],
                         ['Dave K + Sam', 'Dave M + Lee'])
