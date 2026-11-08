"""`points_531_hole_card` — what the score-entry screen draws for one hole
(`~/Downloads/handoff-points-score-entry`).

The handoff's own worked examples, played through the real engine: hole 7,
par 4, SI 5, $1 a point, Paul CH 8 / Dave CH 12 / Sam CH 15 off the low man.
Dave gets no stroke (4 < 5) and Sam gets one (7 >= 5).
"""
from django.test import TestCase

from services.points_531 import (calculate_points_531, points_531_hole_card,
                                 setup_points_531)

from ._helpers import DEFAULT_HOLES, make_foursome, make_round, make_tee, submit_hole


def _holes():
    """The handoff's hole 7: par 4, SI 5, 376 yards.

    The stroke index has to stay a permutation of 1..18, so the hole that
    held 5 takes 7's old 17 — anything else and the course itself is invalid.
    """
    out = []
    for h in DEFAULT_HOLES:
        h = dict(h)
        if h['number'] == 7:
            h.update(par=4, stroke_index=5, yards=376)
        elif h['stroke_index'] == 5:
            h['stroke_index'] = 17
        out.append(h)
    return out


class PointsHoleCardTests(TestCase):

    def setUp(self):
        self.tee = make_tee(holes=_holes())
        self.round = make_round(active_games=['points_531'], course=self.tee.course)
        self.round.bet_unit = 1
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round, [('Paul', 8), ('Dave', 12), ('Sam', 15)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_points_531(self.fs, handicap_mode='strokes_off')

    def _hole7(self, paul, dave, sam):
        submit_hole(self.fs, 7, [(self.pid['Paul'], paul),
                                 (self.pid['Dave'], dave),
                                 (self.pid['Sam'], sam)])
        calculate_points_531(self.fs)
        return points_531_hole_card(self.fs, 7)

    def _name(self, pid):
        # `short_name` auto-fills to initials, so keying on it makes these
        # read 'P'/'D'/'S' and the handoff's examples unrecognisable.
        return next(n for n, i in self.pid.items() if i == pid)

    def _points(self, card):
        return {self._name(r['player_id']): r['points']
                for r in card['points_rows']}

    # ── the hole itself ──────────────────────────────────────────────────

    def test_the_card_carries_the_hole_s_own_geometry(self):
        card = self._hole7(4, 5, 7)
        self.assertEqual((card['par'], card['stroke_index'], card['yards']),
                         (4, 5, 376))

    def test_the_strokes_come_off_the_low_man(self):
        """Dave is 4 clear of Paul and the hole is SI 5, so he gets none;
        Sam is 7 clear and gets one.  The whole example rests on it."""
        by = {self._name(p['player_id']): p
              for p in self._hole7(4, 5, 7)['players']}
        self.assertEqual(by['Paul']['strokes'], 0)
        self.assertEqual(by['Dave']['strokes'], 0)
        self.assertEqual(by['Sam']['strokes'], 1)

    # ── the four splits §4 works through ─────────────────────────────────

    def test_an_outright_hole_pays_five_three_one(self):
        # Sam makes 7 (net 6): Paul 4, Dave 5, Sam 6.
        self.assertEqual(self._points(self._hole7(4, 5, 7)),
                         {'Paul': 5.0, 'Dave': 3.0, 'Sam': 1.0})

    def test_a_tie_for_low_splits_five_and_three(self):
        # Sam makes 5 (net 4) — level with Paul.  4 each, Dave 1.
        self.assertEqual(self._points(self._hole7(4, 5, 5)),
                         {'Paul': 4.0, 'Sam': 4.0, 'Dave': 1.0})

    def test_a_tie_for_second_splits_three_and_one(self):
        # Sam makes 6 (net 5) — level with Dave.  Paul 5, 2 each.
        self.assertEqual(self._points(self._hole7(4, 5, 6)),
                         {'Paul': 5.0, 'Dave': 2.0, 'Sam': 2.0})

    def test_three_level_take_three_each(self):
        self.assertEqual(self._points(self._hole7(5, 5, 6)),
                         {'Paul': 3.0, 'Dave': 3.0, 'Sam': 3.0})

    def test_a_tied_row_says_so(self):
        """The chip has to say it: tied points are not 5, 3 or 1, and a
        golfer reading `4` with no explanation checks it against nothing."""
        card = self._hole7(4, 5, 5)
        tied = {self._name(r['player_id']): r['tied']
                for r in card['points_rows']}
        self.assertEqual(tied, {'Paul': True, 'Sam': True, 'Dave': False})

    def test_the_rows_run_from_low_net_up(self):
        card = self._hole7(4, 5, 7)
        self.assertEqual([r['net'] for r in card['points_rows']], [4, 5, 6])

    # ── the standing ─────────────────────────────────────────────────────

    def test_nine_points_are_paid_on_every_hole_however_they_split(self):
        for scores in ((4, 5, 7), (4, 5, 5), (4, 5, 6), (5, 5, 6)):
            with self.subTest(scores=scores):
                card = self._hole7(*scores)
                self.assertEqual(sum(self._points(card).values()), 9.0)

    def test_the_target_is_three_a_hole_and_counts_the_hole_in_play(self):
        """"target 21 pts thru 7" standing on the 7th."""
        card = self._hole7(4, 5, 7)
        self.assertEqual((card['thru'], card['target']), (7, 21))

    def test_the_standing_is_through_THIS_hole_not_the_round(self):
        """`summary['players']` carries the FINISHED totals, so reading them
        made the tray report the 10th while standing on the 7th.

        **Holes beyond 7 are scored on purpose.**  A fixture that stops at
        the hole being asked about cannot tell the two readings apart — the
        round total and the through-7 total are the same number — so the
        first version of this test passed against the bug it exists to
        catch.  Paul wins all ten outright, so through 7 he has 35 and
        through 10 he has 50.
        """
        for h in range(1, 11):
            submit_hole(self.fs, h, [(self.pid['Paul'], 3),
                                     (self.pid['Dave'], 5),
                                     (self.pid['Sam'], 7)])
        calculate_points_531(self.fs)

        card = points_531_hole_card(self.fs, 7)
        self.assertEqual({self._name(s['player_id']): s['points']
                          for s in card['standing']},
                         {'Paul': 35.0, 'Dave': 21.0, 'Sam': 7.0})
        self.assertEqual(card['target'], 21)
        # ...and the money moves with it: +14 / 0 / -14 at 7, not at 10.
        self.assertEqual({self._name(s['player_id']): s['money']
                          for s in card['standing']},
                         {'Paul': 14.0, 'Dave': 0.0, 'Sam': -14.0})

        # The control: the same card on the 10th reads the 10th.
        later = points_531_hole_card(self.fs, 10)
        self.assertEqual({self._name(s['player_id']): s['points']
                          for s in later['standing']},
                         {'Paul': 50.0, 'Dave': 30.0, 'Sam': 10.0})

    def test_the_money_is_zero_sum(self):
        card = self._hole7(4, 5, 7)
        self.assertEqual(round(sum(s['money'] for s in card['standing']), 2), 0)

    def test_the_last_hole_agrees_with_the_board(self):
        """The as-of-this-hole arithmetic has to land on the engine's own
        round figures when the hole in question is the last one — which is
        what says it is the same calculation and not a lookalike."""
        from services.points_531 import points_531_summary
        for h in range(1, 19):
            submit_hole(self.fs, h, [(self.pid['Paul'], 4),
                                     (self.pid['Dave'], 5),
                                     (self.pid['Sam'], 7)])
        calculate_points_531(self.fs)
        card = points_531_hole_card(self.fs, 18)
        board = {p['player_id']: (p['points'], p['money'])
                 for p in points_531_summary(self.fs)['players']}
        for s in card['standing']:
            self.assertEqual((s['points'], s['money']), board[s['player_id']],
                             f'{s["short"]} disagrees with the board')

    def test_the_last_hole_is_round_over_and_names_the_winner(self):
        for h in range(1, 19):
            submit_hole(self.fs, h, [(self.pid['Paul'], 4),
                                     (self.pid['Dave'], 5),
                                     (self.pid['Sam'], 7)])
        calculate_points_531(self.fs)
        card = points_531_hole_card(self.fs, 18)
        self.assertTrue(card['round_over'])
        self.assertEqual(card['winner']['short'],
                         self.fs.memberships.get(
                             player_id=self.pid['Paul']).player.short_name)
        self.assertEqual(card['winner']['target'], 54)
        self.assertEqual(card['winner']['settles'], 'vs Average')

    def test_a_configured_round_has_a_card_before_anybody_scores(self):
        """No card means no keypad — the failure Rabbit and Sixes both hit.

        The game's status stays `pending` until the first hole is fully
        scored, so gating on it left hole 1 of a fresh round unscoreable.
        """
        card = points_531_hole_card(self.fs, 1)
        self.assertTrue(card, 'hole 1 of a fresh round has no card')
        self.assertFalse(card['hole_complete'])
        self.assertFalse(card['round_over'])
        self.assertEqual(len(card['players']), 3)
        self.assertTrue(all(p['gross'] is None for p in card['players']))
        # ...and the keypad needs the strokes, which do not wait for a score.
        self.assertEqual([p['strokes'] for p in card['players']].count(0), 3,
                         'hole 1 is SI 7; nobody is 7 clear of Paul')

    def test_an_unfinished_hole_is_not_round_over(self):
        self.assertFalse(points_531_hole_card(self.fs, 18)['round_over'])
        self.assertFalse(points_531_hole_card(self.fs, 7)['hole_complete'])

    def test_an_unconfigured_game_returns_nothing(self):
        other = make_round(active_games=['points_531'])
        fs = make_foursome(other, [('A', 0), ('B', 0), ('C', 0)])
        self.assertEqual(points_531_hole_card(fs, 1), {})
