"""One golfer, and the opponent is par.

`handoff-solo-games`. Three variants, all Net, all for fun: stroke play
against par, a Nassau against par (front, back, all 18) and an 18-hole match.

A hole against par: net under = won, net = halved, net over = lost.

**Par is not a player**, so there is no phantom to assert about — these check
that nothing is created for the opponent, because the alternative design
(give par a card) is the one somebody will reach for next.
"""
from django.test import TestCase

from games.models import SoloGame
from services.solo import setup_solo, solo_summary, strokes_by_hole

from ._helpers import make_foursome, make_round, make_tee, submit_hole

# par 4 everywhere, stroke index 1..18 so allowance maths is readable
HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    variant = SoloGame.Variant.STROKE
    hcp = 12

    def setUp(self):
        self.tee = make_tee(holes=HOLES)
        self.round = make_round(self.tee.course, active_games=['solo_stroke'])
        self.fs = make_foursome(self.round, [('Paul', self.hcp)], tee=self.tee)
        self.m = self.fs.memberships.first()
        self.pid = self.m.player_id
        setup_solo(self.round, variant=self.variant, net_percent=100)

    def play(self, hole, gross):
        submit_hole(self.fs, hole, [(self.pid, gross)])

    def s(self):
        return solo_summary(self.round)

    def hole(self, n):
        return next(h for h in self.s()['holes'] if h['hole'] == n)


class ParIsNotAPlayerTests(_Base):
    def test_a_solo_round_has_exactly_one_membership(self):
        """No phantom. Giving par a card would mean giving it a handicap, a
        tee and a place in every grouping rule in the app, to represent a
        number the scorecard already prints."""
        self.assertEqual(self.fs.memberships.count(), 1)
        self.assertFalse(self.fs.memberships.filter(
            player__is_phantom=True).exists())

    def test_the_board_names_the_golfer_and_nothing_else(self):
        d = self.s()
        self.assertEqual(d['player_name'], 'Paul')
        self.assertNotIn('opponent', d)

    def test_there_is_no_money_anywhere_in_it(self):
        d = self.s()
        self.assertTrue(d['for_fun'])
        for key in ('entry_fee', 'pool', 'payouts', 'money', 'settlement'):
            self.assertNotIn(key, d, msg=f'{key} has no business in a solo game')


class AHoleAgainstParTests(_Base):
    def test_under_par_is_won_level_is_halved_over_is_lost(self):
        self.play(1, 3)                 # SI 1 — a stroke — net 2 on a par 4
        self.play(2, 4)                 # SI 2 — a stroke — net 3
        self.play(13, 4)                # SI 13 — no stroke at 12 — net 4
        self.play(14, 5)                # no stroke — net 5
        self.assertEqual(self.hole(1)['result'], 'won')
        self.assertEqual(self.hole(2)['result'], 'won')
        self.assertEqual(self.hole(13)['result'], 'halved')
        self.assertEqual(self.hole(14)['result'], 'lost')

    def test_an_unplayed_hole_has_no_result(self):
        self.assertIsNone(self.hole(7)['result'])
        self.assertIsNone(self.hole(7)['net'])


class TheAllowanceTests(_Base):
    def test_100_percent_gives_the_course_handicap(self):
        alloc = strokes_by_hole(self.fs, 100)
        self.assertEqual(sum(alloc.values()), 12)

    def test_below_100_gives_fewer(self):
        self.assertEqual(sum(strokes_by_hole(self.fs, 50).values()), 6)

    def test_ABOVE_100_gives_more(self):
        """No other game in the app allows it. Harmless when nobody is
        paying, and the point of a solo allowance is to make par beatable."""
        self.assertEqual(sum(strokes_by_hole(self.fs, 130).values()), 16)

    def test_the_extra_strokes_land_where_a_bigger_handicap_would(self):
        """125% of 12 is 15 — ONE stroke on each of the fifteen hardest
        holes, exactly as a 15 handicap gets them. (I first wrote this
        expecting two strokes on the lowest three; second strokes do not
        begin until 18, which is the whole course.)"""
        alloc = strokes_by_hole(self.fs, 125)
        self.assertEqual(sum(alloc.values()), 15)
        self.assertEqual(alloc[1], 1)
        self.assertEqual(alloc[15], 1)
        self.assertEqual(alloc[16], 0)

    def test_the_slider_ceiling_still_fits_inside_one_round(self):
        """130% of 12 is 16 — still one stroke a hole at most. A 12 handicap
        cannot reach a second stroke anywhere on the slider; a 15 can."""
        self.assertEqual(set(strokes_by_hole(self.fs, 130).values()), {0, 1})

    def test_a_big_handicap_CAN_reach_a_second_stroke(self):
        """Which is why the setup screen's sentence has a branch for it: 30
        at 130% is 39 — one on every hole and a second on 21."""
        m = self.fs.memberships.first()
        m.playing_handicap = 30
        m.course_handicap = 30
        m.save(update_fields=['playing_handicap', 'course_handicap'])
        alloc = strokes_by_hole(self.fs, 130)
        self.assertEqual(sum(alloc.values()), 39)
        self.assertEqual(alloc[1], 3)


class StrokePlayTests(_Base):
    def test_net_total_against_par(self):
        self.play(1, 5)     # stroke → net 4 → level
        self.play(2, 6)     # stroke → net 5 → +1
        self.play(14, 3)    # no stroke → net 3 → -1
        d = self.s()['stroke']
        self.assertEqual(d['to_par'], 0)
        self.assertEqual(d['thru'], 3)

    def test_it_counts_only_what_has_been_played(self):
        self.play(1, 4)
        self.assertEqual(self.s()['stroke']['thru'], 1)


class NassauTests(_Base):
    variant = SoloGame.Variant.NASSAU

    def test_three_matches_against_par(self):
        d = self.s()['nassau']
        for key in ('front', 'back', 'overall'):
            self.assertIn(key, d)
        self.assertEqual(d['front']['holes'], 9)
        self.assertEqual(d['overall']['holes'], 18)

    def test_the_front_nine_is_won_hole_by_hole(self):
        for h in range(1, 4):
            self.play(h, 3)           # stroke on each → net 2 → won
        self.assertEqual(self.s()['nassau']['front']['up'], 3)
        self.assertEqual(self.s()['nassau']['overall']['up'], 3)

    def test_a_halved_hole_moves_nothing(self):
        self.play(13, 4)              # no stroke → net 4 → halved
        self.assertEqual(self.s()['nassau']['front']['up'], 0)

    def test_the_back_nine_is_its_own_match(self):
        for h in range(10, 14):
            self.play(h, 6)           # over par → lost
        d = self.s()['nassau']
        self.assertEqual(d['front']['up'], 0)
        self.assertLess(d['back']['up'], 0)


class AutoPressTests(_Base):
    """Paul: "put autopress as an option on Nassau."

    A press here is an extra MATCH, not an extra bet — there is no stake to
    double, so what it buys is a way back into a nine you have already lost.
    Fires at 2, 4, 6 and 8 down, each once, starting the NEXT hole and
    running to the end of that nine: the same rule as a real Nassau
    (`services/nassau.AUTO_TOP_THRESHOLDS`) so nobody has to learn a second
    one.

    With CH 12 on this card (par 4, stroke index 1..18) holes 1-12 get a
    stroke, so a 6 loses a hole on the front, a 5 halves it and a 4 wins it.
    """
    variant = SoloGame.Variant.NASSAU

    def setUp(self):
        super().setUp()
        setup_solo(self.round, variant=self.variant, net_percent=100,
                   auto_press=True)

    def presses(self, nine='front'):
        return self.s()['nassau'][nine]['presses']

    def test_it_is_off_unless_it_is_asked_for(self):
        """Default off, as `press_mode` is in a real Nassau: a press is
        something a group opts into, and solo's whole design is one slider."""
        setup_solo(self.round, variant=self.variant, net_percent=100)
        self.play(1, 6)
        self.play(2, 6)
        self.assertEqual(self.presses(), [])
        self.assertFalse(self.s()['nassau']['auto_press'])

    def test_a_press_fires_at_two_down_and_starts_on_the_next_hole(self):
        self.play(1, 6)
        self.assertEqual(self.presses(), [])        # one down presses nothing
        self.play(2, 6)
        p, = self.presses()
        self.assertEqual(p['trigger_hole'], 2)
        self.assertEqual(p['start'], 3)
        self.assertEqual(p['end'], 9)
        self.assertEqual(p['holes'], 7)

    def test_the_press_is_its_own_match(self):
        """The nine keeps its margin; the press counts only its own holes."""
        self.play(1, 6)
        self.play(2, 6)
        self.play(3, 4)
        self.play(4, 4)
        d = self.s()['nassau']['front']
        self.assertEqual(d['up'], 0)                # two lost, two won
        self.assertEqual(d['presses'][0]['up'], 2)  # both wins are the press's

    def test_each_level_fires_once(self):
        """Two down, back to one, two down again — still one press. Going on
        to four down opens a second."""
        self.play(1, 6)
        self.play(2, 6)
        self.play(3, 4)                             # back to one down
        self.play(4, 6)                             # two down again
        self.assertEqual(len(self.presses()), 1)
        self.play(5, 6)
        self.play(6, 6)                             # four down
        self.assertEqual(len(self.presses()), 2)
        self.assertEqual(self.presses()[1]['start'], 7)

    def test_par_never_presses(self):
        """The one departure from the real game. A two-sided Nassau fires on
        plus or minus 2 because either side may be the one losing and either
        may call it; par has no agency, so a golfer two UP presses nothing."""
        self.play(1, 4)
        self.play(2, 4)
        self.assertEqual(self.s()['nassau']['front']['up'], 2)
        self.assertEqual(self.presses(), [])

    def test_the_last_hole_of_a_nine_presses_nothing(self):
        """Nothing left to press over, so no press — not an empty one."""
        self.play(8, 6)
        self.play(9, 6)
        self.assertEqual(self.presses(), [])

    def test_the_overall_bet_has_no_presses(self):
        """Presses belong to the two nines, as in the real game."""
        self.play(1, 6)
        self.play(2, 6)
        self.assertEqual(self.s()['nassau']['overall']['presses'], [])

    def test_the_back_nine_presses_on_its_own(self):
        """And its press cannot reach past the 18th. Holes 13-18 get no
        stroke at CH 12, so a 5 is what loses one there."""
        self.play(10, 6)
        self.play(11, 6)
        self.assertEqual(self.presses('front'), [])
        p, = self.presses('back')
        self.assertEqual(p['start'], 12)
        self.assertEqual(p['end'], 18)
        self.play(13, 5)                            # no stroke → net 5 → lost
        self.assertEqual(self.presses('back')[0]['up'], -1)

    def test_a_press_closes_out_like_any_match(self):
        self.play(1, 6)
        self.play(2, 6)
        for h in range(3, 9):                       # six up with one to play
            self.play(h, 4)
        self.assertIsNotNone(self.presses()[0]['decided'])
        self.assertIn('&', self.presses()[0]['decided'])

    def test_a_corrected_score_un_fires_a_press(self):
        """Nothing is stored: a press is derived from the holes on every read,
        so a 6 entered by mistake on the 2nd does not leave a press behind."""
        self.play(1, 6)
        self.play(2, 6)
        self.assertEqual(len(self.presses()), 1)
        self.play(2, 4)                             # it was a 4
        self.assertEqual(self.presses(), [])

    def test_the_switch_survives_a_change_of_variant(self):
        """Stored for every variant and read only by the Nassau, so a golfer
        who tries Match Play and comes back finds his switch where it was."""
        setup_solo(self.round, variant=SoloGame.Variant.MATCH,
                   net_percent=100, auto_press=True)
        self.round.refresh_from_db()
        self.assertNotIn('nassau', self.s())
        setup_solo(self.round, variant=self.variant, net_percent=100,
                   auto_press=True)
        self.assertTrue(self.s()['nassau']['auto_press'])


class MatchPlayTests(_Base):
    variant = SoloGame.Variant.MATCH

    def test_an_eighteen_hole_match(self):
        self.play(1, 3)
        d = self.s()['match']
        self.assertEqual(d['up'], 1)
        self.assertEqual(d['to_play'], 17)

    def test_it_shows_the_closing_score_once_decided(self):
        """Six up with five to play is 6&5 — and the card stays open."""
        for h in range(1, 14):
            self.play(h, 3 if h <= 13 else 4)
        d = self.s()['match']
        self.assertIsNotNone(d['decided'])
        self.assertIn('&', d['decided'])

    def test_it_is_not_decided_while_it_can_still_be_caught(self):
        self.play(1, 3)
        self.assertIsNone(self.s()['match']['decided'])

    def test_play_continues_after_it_is_decided(self):
        """The handoff is explicit: show the closing score and keep the card
        open to 18. So a later hole still records a result."""
        for h in range(1, 14):
            self.play(h, 3)
        self.play(18, 6)
        self.assertEqual(self.hole(18)['result'], 'lost')


class NotConfiguredTests(TestCase):
    def test_a_round_without_a_solo_game_says_so(self):
        tee = make_tee(holes=HOLES)
        rnd = make_round(tee.course)
        make_foursome(rnd, [('Paul', 10)], tee=tee)
        self.assertEqual(solo_summary(rnd), {'configured': False})
