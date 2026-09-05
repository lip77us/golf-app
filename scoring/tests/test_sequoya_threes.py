"""
scoring/tests/test_sequoya_threes.py
------------------------------------
Sequoya 3s (docs/design-review/handoff-sequoya-threes/README.md).

Weighted towards the two rules the packet calls non-negotiable: **the rotation
is derived, not chosen** — so every golfer partners every other exactly twice —
and **a press is a separate BET, never a doubling**, computed from the same net
table as the match it sits inside so the two can never contradict each other.
"""
from decimal import Decimal

from django.test import TestCase

from games.models import SequoyaThreesGame
from services.sequoya_threes import (MATCH_HOLES, call_press, pairing_for_match,
                                     remove_press,
                                     pairings, sequoya_threes_summary,
                                     setup_sequoya_threes)
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class RotationTests(TestCase):
    """Four golfers split 2v2 in exactly three ways and there is no fourth."""

    def setUp(self):
        self.ids = [10, 20, 30, 40]

    def test_there_are_exactly_three_pairings(self):
        rot = pairings(self.ids, [10, 20])
        self.assertEqual(len(rot), 3)
        seen = {frozenset(s1) for s1, _ in rot}
        self.assertEqual(len(seen), 3)

    def test_match_one_is_the_pairing_the_group_chose(self):
        s1, s2 = pairing_for_match(self.ids, [10, 30], 1)
        self.assertEqual(set(s1), {10, 30})
        self.assertEqual(set(s2), {20, 40})

    def test_matches_four_to_six_repeat_one_to_three(self):
        """The repeat is the format, not an accident of the modulo."""
        for m in (1, 2, 3):
            a1, a2 = pairing_for_match(self.ids, [10, 20], m)
            b1, b2 = pairing_for_match(self.ids, [10, 20], m + 3)
            self.assertEqual(set(a1), set(b1))
            self.assertEqual(set(a2), set(b2))

    def test_every_golfer_partners_every_other_exactly_twice(self):
        counts = {p: {} for p in self.ids}
        for m in range(1, 7):
            s1, s2 = pairing_for_match(self.ids, [10, 20], m)
            for side in (s1, s2):
                x, y = side
                counts[x][y] = counts[x].get(y, 0) + 1
                counts[y][x] = counts[y].get(x, 0) + 1
        for p in self.ids:
            others = [q for q in self.ids if q != p]
            self.assertEqual(sorted(counts[p].keys()), sorted(others))
            self.assertTrue(all(v == 2 for v in counts[p].values()),
                            f'{p} -> {counts[p]}')

    def test_the_six_matches_are_three_holes_each_and_cover_the_round(self):
        self.assertEqual(MATCH_HOLES,
                         [(1, 3), (4, 6), (7, 9), (10, 12), (13, 15), (16, 18)])


class SequoyaScoringTests(TestCase):
    """Gross, $5 a man, so the nets are the scores and the money is countable."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course,
                                active_games=['sequoya_threes'])
        self.round.bet_unit     = Decimal('5.00')
        self.round.primary_game = 'sequoya_threes'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 0), ('Cal', 0), ('Dee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_sequoya_threes(
            self.fs, [self.pid['Ann'], self.pid['Ben']],
            handicap_mode='gross', bet_amount=5,
            press_mode=SequoyaThreesGame.PRESS_NONE)

    def _play(self, hole, a, b, c, d):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a), (self.pid['Ben'], b),
                                    (self.pid['Cal'], c), (self.pid['Dee'], d)])

    def _s(self):
        return sequoya_threes_summary(self.fs)

    def _match(self, n):
        return self._s()['matches'][n - 1]

    # -- the money --------------------------------------------------------

    def test_a_won_match_pays_every_man_not_every_pair(self):
        """Two winners each collect the stake; both losers are down it."""
        for h in (1, 2):
            self._play(h, 4, 4, 5, 5)          # Ann & Ben take both
        money = {p['name']: p['money'] for p in self._s()['players']}
        self.assertEqual(money['Ann'], 5)
        self.assertEqual(money['Ben'], 5)
        self.assertEqual(money['Cal'], -5)
        self.assertEqual(money['Dee'], -5)

    def test_the_money_is_zero_sum(self):
        for h in (1, 2):
            self._play(h, 4, 4, 5, 5)
        self.assertAlmostEqual(
            sum(p['money'] for p in self._s()['players']), 0, places=2)

    def test_a_halved_match_pays_nothing_and_does_not_carry(self):
        """A carryover across a pairing change would owe money from a pair
        that no longer exists."""
        for h in (1, 2, 3):
            self._play(h, 4, 4, 4, 4)
        self.assertEqual(self._match(1)['bets'][0]['result'], 0)
        self.assertTrue(all(p['money'] == 0 for p in self._s()['players']))
        # Match 2 is worth its own stake, not two.
        self.assertEqual(self._match(2)['at_risk'], 5)

    # -- closing early ------------------------------------------------------

    def test_a_match_closes_when_the_lead_exceeds_the_holes_left(self):
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 5, 5)              # 2 up with 1 to play
        bet = self._match(1)['bets'][0]
        self.assertEqual(bet['closed_on'], 2)
        self.assertEqual(bet['result'], 1)

    def test_one_up_with_two_to_play_is_not_closed(self):
        self._play(1, 4, 4, 5, 5)
        bet = self._match(1)['bets'][0]
        self.assertIsNone(bet['closed_on'])
        self.assertIsNone(bet['result'])

    # -- the rotation, over real scores -------------------------------------

    def test_the_pairing_changes_at_every_third_hole(self):
        s = self._s()
        self.assertNotEqual({p['player_id'] for p in s['matches'][0]['side1']},
                            {p['player_id'] for p in s['matches'][1]['side1']})
        self.assertEqual({p['player_id'] for p in s['matches'][0]['side1']},
                         {p['player_id'] for p in s['matches'][3]['side1']})


class PressTests(TestCase):
    """A press is a separate bet at the same amount — never a doubling."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course,
                                active_games=['sequoya_threes'])
        self.round.bet_unit     = Decimal('5.00')
        self.round.primary_game = 'sequoya_threes'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 0), ('Cal', 0), ('Dee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_sequoya_threes(
            self.fs, [self.pid['Ann'], self.pid['Ben']],
            handicap_mode='gross', bet_amount=5,
            press_mode=SequoyaThreesGame.PRESS_MANUAL_AUTO)

    def _play(self, hole, a, b, c, d):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a), (self.pid['Ben'], b),
                                    (self.pid['Cal'], c), (self.pid['Dee'], d)])

    def _match(self, n=1):
        return sequoya_threes_summary(self.fs)['matches'][n - 1]

    def test_winning_the_first_hole_opens_an_auto_press(self):
        self._play(1, 4, 4, 5, 5)
        kinds = [b['kind'] for b in self._match()['bets']]
        self.assertEqual(kinds, ['match', 'auto_press'])

    def test_the_auto_press_covers_only_the_holes_that_remain(self):
        self._play(1, 4, 4, 5, 5)
        press = self._match()['bets'][1]
        self.assertEqual(press['holes'], [2, 3])

    def test_halving_the_first_hole_opens_nothing(self):
        self._play(1, 4, 4, 4, 4)
        self.assertEqual([b['kind'] for b in self._match()['bets']], ['match'])

    def test_the_press_is_the_same_amount_not_a_doubling(self):
        self._play(1, 4, 4, 5, 5)
        bets = self._match()['bets']
        self.assertEqual(bets[0]['amount'], bets[1]['amount'])
        self.assertEqual(self._match()['at_risk'], 10)

    def test_a_press_can_be_won_by_the_side_that_lost_the_match(self):
        """Normal, and never folded into a match total."""
        self._play(1, 4, 4, 5, 5)          # Ann/Ben win hole 1 -> auto press
        self._play(2, 5, 5, 4, 4)          # Cal/Dee take 2
        self._play(3, 5, 5, 4, 4)          # and 3 — they win the press
        bets = self._match()['bets']
        self.assertEqual(bets[0]['result'], 2, 'match went to Cal & Dee')
        self.assertEqual(bets[1]['result'], 2, 'so did the press')
        # Two separate bets, so the pair collects twice over.
        money = {p['name']: p['money']
                 for p in sequoya_threes_summary(self.fs)['players']}
        self.assertEqual(money['Cal'], 10)
        self.assertEqual(money['Ann'], -10)

    def test_a_press_can_be_halved_while_the_match_is_won(self):
        self._play(1, 4, 4, 5, 5)          # Ann/Ben 1 up, press opens
        self._play(2, 4, 4, 4, 4)
        self._play(3, 4, 4, 4, 4)
        bets = self._match()['bets']
        self.assertEqual(bets[0]['result'], 1, 'match won')
        self.assertEqual(bets[1]['result'], 0, 'press halved')
        money = {p['name']: p['money']
                 for p in sequoya_threes_summary(self.fs)['players']}
        self.assertEqual(money['Ann'], 5, 'the match only')

    # -- the hand-called press ---------------------------------------------

    def _manual(self, n=1):
        return [b for b in self._match(n)['bets']
                if b['kind'] == 'manual_press'][0]

    def test_a_hand_called_press_cannot_sit_on_top_of_an_auto_press(self):
        """The auto press IS the press. A second bet over the holes it already
        covers can only ever settle the same way — a double, not a press."""
        self._play(1, 4, 4, 5, 5)          # Ann/Ben win 1 -> auto press on 2-3
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=1, side=2,
                       called_by_id=self.pid['Cal'], current_hole=2)

    def test_a_hand_called_press_covers_the_hole_being_played(self):
        """It is called on the TEE, so it covers the hole about to be played.

        Starting it on the NEXT hole made the last hole of a match unpressable
        — hole 4 belongs to the next match and a different pairing — which is
        every hand-called press there is, since one can only exist in a match
        whose first hole was halved.
        """
        self._play(1, 4, 4, 4, 4)          # halved -> no auto press
        self._play(2, 5, 5, 4, 4)          # Cal/Dee 1 up
        call_press(self.fs, match_index=1, side=1,
                   called_by_id=self.pid['Ann'], current_hole=3)
        self.assertEqual(self._manual()['holes'], [3])

    def test_a_press_never_covers_a_hole_already_in_the_book(self):
        """Called while looking BACK at a played hole it starts on the next
        one, and here there is no next one — nobody may press a result they
        have seen."""
        self._play(1, 4, 4, 4, 4)
        self._play(2, 5, 5, 4, 4)
        self._play(3, 5, 5, 4, 4)
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=1, side=1,
                       called_by_id=self.pid['Ann'], current_hole=3)

    def test_it_cannot_be_called_before_a_hole_is_decided(self):
        """On the first tee of a match there is nothing to trail after."""
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=1, side=2,
                       called_by_id=self.pid['Cal'], current_hole=1)

    def test_a_square_match_cannot_be_pressed(self):
        self._play(1, 4, 4, 4, 4)          # halved, so no auto press either
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=1, side=2,
                       called_by_id=self.pid['Cal'], current_hole=2)

    def test_only_the_side_that_is_down_may_press(self):
        """Enforced in the service, not only in the UI — the offer card states
        it, and a rule enforced only in the UI is not enforced."""
        self._play(1, 4, 4, 4, 4)
        self._play(2, 5, 5, 4, 4)          # Cal/Dee 1 up
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=1, side=2,
                       called_by_id=self.pid['Cal'], current_hole=3)

    def test_only_one_hand_called_press_per_match(self):
        self._play(1, 4, 4, 4, 4)
        self._play(2, 5, 5, 4, 4)
        call_press(self.fs, match_index=1, side=1,
                   called_by_id=self.pid['Ann'], current_hole=3)
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=1, side=1,
                       called_by_id=self.pid['Ann'], current_hole=3)

    def test_the_last_hole_can_be_pressed_after_losing_the_first_two(self):
        """Two down with one to play, an auto press already running: the match
        bet is closed out and the auto press is dormie, so a fresh level bet
        over the last hole repeats neither. Refusing it merely because an auto
        press existed locked out the classic press."""
        self._play(1, 5, 5, 4, 4)          # Cal/Dee win 1 -> auto press on 2-3
        self._play(2, 5, 5, 4, 4)          # and 2 -> match closed out 2 & 1
        call_press(self.fs, match_index=1, side=1,
                   called_by_id=self.pid['Ann'], current_hole=3)
        self.assertEqual(self._manual()['holes'], [3])
        self.assertEqual([b['kind'] for b in self._match()['bets']],
                         ['match', 'auto_press', 'manual_press'],
                         'all three are real, and none repeats another')

    def test_a_press_that_would_repeat_a_live_level_bet_is_refused(self):
        """The auto press opened over 2-3 and is level, so a hand-called press
        over 2-3 is the same bet twice."""
        self._play(1, 4, 4, 5, 5)          # Ann/Ben win 1 -> auto press on 2-3
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=1, side=2,
                       called_by_id=self.pid['Cal'], current_hole=2)

    def test_a_match_carries_at_most_three_bets(self):
        """The match, the auto press and one called by hand — the ceiling the
        setup screen prints."""
        self._play(1, 5, 5, 4, 4)
        self._play(2, 5, 5, 4, 4)
        call_press(self.fs, match_index=1, side=1,
                   called_by_id=self.pid['Ann'], current_hole=3)
        self.assertEqual(self._match()['bet_count'], 3)

    def test_presses_are_refused_entirely_when_the_round_is_not_playing_them(self):
        setup_sequoya_threes(self.fs, [self.pid['Ann'], self.pid['Ben']],
                             handicap_mode='gross', bet_amount=5,
                             press_mode=SequoyaThreesGame.PRESS_NONE)
        self._play(1, 4, 4, 4, 4)
        self._play(2, 5, 5, 4, 4)
        self.assertEqual([b['kind'] for b in self._match()['bets']], ['match'])
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=1, side=1,
                       called_by_id=self.pid['Ann'], current_hole=3)


class SettlementTests(TestCase):
    """Only the four nets are real; payments are derived from them."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course,
                                active_games=['sequoya_threes'])
        self.round.bet_unit     = Decimal('5.00')
        self.round.primary_game = 'sequoya_threes'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 0), ('Cal', 0), ('Dee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_sequoya_threes(self.fs, [self.pid['Ann'], self.pid['Ben']],
                             handicap_mode='gross', bet_amount=5,
                             press_mode=SequoyaThreesGame.PRESS_NONE)
        for h in (1, 2):
            submit_hole(self.fs, h, [(self.pid['Ann'], 4), (self.pid['Ben'], 4),
                                     (self.pid['Cal'], 5), (self.pid['Dee'], 5)])

    def test_four_golfers_settle_in_two_handovers(self):
        t = sequoya_threes_summary(self.fs)['transfers']
        self.assertEqual(len(t), 2)

    def test_the_handovers_clear_every_net(self):
        s = sequoya_threes_summary(self.fs)
        moved = {p['player_id']: 0.0 for p in s['players']}
        for t in s['transfers']:
            moved[t['from']] -= t['amount']
            moved[t['to']]   += t['amount']
        for p in s['players']:
            self.assertAlmostEqual(moved[p['player_id']], p['money'], places=2)

    def test_the_board_ranks_by_money_not_matches_won(self):
        s = sequoya_threes_summary(self.fs)
        self.assertEqual([p['money'] for p in s['players']],
                         sorted((p['money'] for p in s['players']),
                                reverse=True))

    def test_the_scorecard_carries_the_side_on_every_score(self):
        """The pairing rotates every third hole, so the side rides on each
        SCORE rather than on the golfer — a per-player side would be wrong
        from hole 4 onward."""
        sc = sequoya_threes_summary(self.fs)['scorecard']
        self.assertEqual(len(sc['holes']), 18)
        # The order score entry draws: the foursome's own, oldest membership
        # first. The two used to run unordered queries and could disagree.
        self.assertEqual([p['name'] for p in sc['players']],
                         ['Ann', 'Ben', 'Cal', 'Dee'])

        def side(hole, name):
            h = sc['holes'][hole - 1]
            return next(e['team'] for e in h['scores']
                        if e['player_id'] == self.pid[name])

        # Ann & Ben are side 1 of match 1 ...
        self.assertEqual(side(1, 'Ann'), side(1, 'Ben'))
        # ... and split up in match 2, which the grid has to say.
        self.assertNotEqual(side(4, 'Ann'), side(4, 'Ben'))

    def test_the_scorecard_tints_the_winning_side_not_a_golfer(self):
        h1 = sequoya_threes_summary(self.fs)['scorecard']['holes'][0]
        self.assertEqual(h1['winner_team'], 1, 'Ann & Ben won hole 1')
        self.assertEqual(h1['par'], 4)
        self.assertIsNotNone(h1['stroke_index'])

    def test_the_scorecard_shows_strokes_on_holes_nobody_has_played(self):
        """The allocation is a fact about the card and the handicap, so it is
        known before a ball is struck. Inferring it from gross - net showed a
        stroke only once the hole was in the book — by which point the golfer
        no longer needed to know."""
        setup_sequoya_threes(
            self.fs, [self.pid['Ann'], self.pid['Ben']],
            handicap_mode='net', bet_amount=5,
            press_mode=SequoyaThreesGame.PRESS_MANUAL_AUTO)
        # Cal is off the stick and Dee is not, so Dee has strokes to show.
        for name, idx in (('Ann', 0), ('Ben', 0), ('Cal', 0), ('Dee', 18)):
            m = self.fs.memberships.get(player_id=self.pid[name])
            m.playing_handicap = idx
            m.save(update_fields=['playing_handicap'])

        sc = sequoya_threes_summary(self.fs)['scorecard']
        last = sc['holes'][-1]                     # hole 18, unplayed
        dee  = next(e for e in last['scores']
                    if e['player_id'] == self.pid['Dee'])
        self.assertIsNone(dee['gross'], 'nobody has played it')
        self.assertEqual(dee['strokes'], 1, 'but the stroke is already known')

    def test_a_halved_or_unplayed_hole_tints_nobody(self):
        sc = sequoya_threes_summary(self.fs)['scorecard']
        self.assertIsNone(sc['holes'][2]['winner_team'], 'hole 3 unplayed')

    def test_the_exposure_ceiling_follows_the_press_mode(self):
        """No presses is 1x, Auto is 2x, and Manual + Auto is 3x — a match can
        carry the match bet, an auto press and one called by hand."""
        e = sequoya_threes_summary(self.fs)['exposure']
        self.assertEqual(e['no_presses'], 30)
        self.assertEqual(e['with_auto'],  60)
        self.assertEqual(e['ceiling'],    30, 'this round plays no presses')

        setup_sequoya_threes(self.fs, [self.pid['Ann'], self.pid['Ben']],
                             handicap_mode='gross', bet_amount=5,
                             press_mode=SequoyaThreesGame.PRESS_MANUAL_AUTO)
        self.assertEqual(sequoya_threes_summary(self.fs)['exposure']['ceiling'],
                         90)
