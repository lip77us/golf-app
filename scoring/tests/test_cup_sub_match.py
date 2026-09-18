"""
scoring/tests/test_cup_sub_match.py
-----------------------------------
`_compute_sub_match` is the one place that decides a cup singles leg: whether
it is dormie, which hole closed it, and how many holes were left. It takes the
group's play order, and every caller must pass it.

That is not a style rule. The BACK NINE is the half a shotgun scrambles: from
the 13th a group plays 13..18 and then 10, 11, 12, so hole 17 is the leg's
fifth hole and hole 12 its last. Without the order the function walks 10..18 by
number, closes the leg on the wrong hole, and — in `services/ryder_cup.py` —
writes the cup POINTS from that answer.
"""
import pathlib
import re

from django.test import SimpleTestCase

from services.cup_singles import _compute_sub_match

# A shotgun from the 13th.
SHOTGUN = [13, 14, 15, 16, 17, 18] + list(range(1, 13))
# The back nine in that group's order: 13..18 first, 10, 11, 12 last.
B9_IN_ORDER = [13, 14, 15, 16, 17, 18, 10, 11, 12]


def _p1_wins(holes):
    """Hole rows where player 1 wins every hole given."""
    return [{'hole_number': h, 'p1_net': 4, 'p2_net': 5} for h in holes]


class SubMatchPlayOrderTests(SimpleTestCase):

    def test_the_back_nine_closes_on_its_own_fifth_hole(self):
        # Five straight wins into a nine-hole leg leaves four holes: dormie.
        five = _p1_wins(B9_IN_ORDER[:5])          # 13, 14, 15, 16, 17
        sub = _compute_sub_match(five, 10, 18, order=SHOTGUN)
        self.assertEqual(sub['status'], 'complete')
        self.assertEqual(sub['result'], 'player1')
        self.assertEqual(sub['finished_on_hole'], 17)
        self.assertEqual(sub['holes_to_play'], 4)   # 18, 10, 11, 12

    def test_without_the_order_the_same_holes_close_on_the_wrong_hole(self):
        """Walking 10..18 by number puts 13 fourth instead of first, so the
        leg goes dormie a hole early: closed on 16 with two left, when the
        group had actually played five holes of nine with four to go. This is
        the answer `services/ryder_cup.py` used to award cup POINTS from —
        and it is wrong in both directions, hole and count."""
        five = _p1_wins(B9_IN_ORDER[:5])
        sub = _compute_sub_match(five, 10, 18)      # no order
        self.assertEqual(sub['finished_on_hole'], 16)
        self.assertEqual(sub['holes_to_play'], 2)

        with_order = _compute_sub_match(five, 10, 18, order=SHOTGUN)
        self.assertNotEqual(sub['finished_on_hole'],
                            with_order['finished_on_hole'])
        self.assertNotEqual(sub['holes_to_play'],
                            with_order['holes_to_play'])

    def test_a_leg_that_runs_to_its_last_hole_has_nothing_left(self):
        # Alternate so the margin never exceeds what remains.
        rows = []
        for i, h in enumerate(B9_IN_ORDER):
            rows.append({'hole_number': h,
                         'p1_net': 4 if i % 2 == 0 else 5,
                         'p2_net': 5 if i % 2 == 0 else 4})
        sub = _compute_sub_match(rows, 10, 18, order=SHOTGUN)
        self.assertEqual(sub['status'], 'complete')
        self.assertEqual(sub['finished_on_hole'], 12,
                         'hole 12 is the last back-nine hole this group plays')
        self.assertEqual(sub['holes_to_play'], 0,
                         '"1 up", never "1&0"')

    def test_an_undecided_leg_reports_no_holes_to_play(self):
        sub = _compute_sub_match(_p1_wins([13, 14]), 10, 18, order=SHOTGUN)
        self.assertEqual(sub['status'], 'in_progress')
        self.assertIsNone(sub['holes_to_play'])

    def test_an_unplayed_leg_reports_no_holes_to_play(self):
        sub = _compute_sub_match(_p1_wins([13, 14]), 1, 9, order=SHOTGUN)
        self.assertEqual(sub['status'], 'pending')
        self.assertIsNone(sub['holes_to_play'])

    def test_a_round_from_the_first_is_the_degenerate_case(self):
        """Where `18 - finished_on_hole` happens to be right — which is why
        this survived so long."""
        five = _p1_wins([10, 11, 12, 13, 14])
        sub = _compute_sub_match(five, 10, 18, order=list(range(1, 19)))
        self.assertEqual(sub['status'], 'complete')
        self.assertEqual(sub['finished_on_hole'], 14)
        self.assertEqual(sub['holes_to_play'], 4)
        self.assertEqual(18 - sub['finished_on_hole'], sub['holes_to_play'])


class EveryCallerPassesThePlayOrderTests(SimpleTestCase):
    """The `order` argument defaults to 1..18 so the function stays usable on
    its own — which means a caller that forgets it gets a plausible wrong
    answer instead of an error. Three files called it without the order for
    months, one of them while writing cup points. So the call sites are the
    invariant."""

    def test_no_service_calls_it_without_an_order(self):
        root  = pathlib.Path(__file__).resolve().parents[2] / 'services'
        calls = re.compile(r'_compute_sub_match\(([^)]*)\)', re.S)
        missing = []
        for path in sorted(root.glob('*.py')):
            src = path.read_text()
            for m in calls.finditer(src):
                args = m.group(1)
                if args.startswith('holes_data:'):
                    continue                       # the definition itself
                if 'order' not in args:
                    line = src[:m.start()].count('\n') + 1
                    missing.append(f'{path.name}:{line}')
        self.assertEqual(missing, [],
                         'these call _compute_sub_match without the group\'s '
                         'play order, so they are wrong on every shotgun: '
                         + ', '.join(missing))
