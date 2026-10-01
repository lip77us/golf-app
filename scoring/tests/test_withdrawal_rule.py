"""
scoring/tests/test_withdrawal_rule.py
-------------------------------------
**A withdrawal is a point in the round, not a hole number.**

`services/withdrawal.py` is the one place that rule lives. Skins, 40 Balls and
Spots each carried their own copy comparing hole NUMBERS
(``h <= withdrew_after_hole``), which is the same integer only when the round
starts on the 1st — and a cup day is very often a shotgun.

Off the 13th a group plays 13-18 then 1-12. A man who walks in after the 2nd
has played EIGHT holes, and six of them (13 through 18) carry a number higher
than 2. The hole-number test drops him from the holes he played and keeps him
on the ones he missed: inverted, not merely off by one.

Every existing withdrawal test in the repo starts on the 1st, where position
and number cannot be told apart — which is why three games shipped the bug and
why the tests here are all shotguns.
"""
from django.test import TestCase

from services.withdrawal import (
    active_count, active_pids, is_active, killed_holes, play_plan,
)
from ._helpers import DEFAULT_HOLES, make_foursome, make_player, make_round, \
    make_tee


class _Shotgun(TestCase):
    """Four golfers off the 13th: play order 13-18, then 1-12."""

    start = 13

    def setUp(self):
        tee = make_tee(holes=DEFAULT_HOLES)
        self.round = make_round(tee.course)
        self.round.starting_hole = self.start
        self.round.save(update_fields=['starting_hole'])
        self.ps = [make_player(n, 10) for n in ('A', 'B', 'C', 'D')]
        self.fs = make_foursome(
            self.round, [(p, 10) for p in self.ps], tee=tee)
        self.order, self.positions = play_plan(self.fs)

    def _wd(self, player, after_hole, *, killed=False):
        m = self.fs.memberships.get(player=player)
        m.withdrew_after_hole = after_hole
        m.withdrew_killed_next_hole = killed
        m.save(update_fields=['withdrew_after_hole',
                              'withdrew_killed_next_hole'])
        return m

    @property
    def members(self):
        return list(self.fs.memberships.select_related('player'))


class PlayOrderTests(_Shotgun):
    def test_the_order_wraps(self):
        self.assertEqual(self.order,
                         list(range(13, 19)) + list(range(1, 13)))
        self.assertEqual(self.positions[13], 0)
        self.assertEqual(self.positions[1], 6)
        self.assertEqual(self.positions[12], 17)


class IsActiveTests(_Shotgun):
    def test_holes_he_PLAYED_keep_him_in(self):
        m = self._wd(self.ps[1], 2)      # played 13-18 and 1-2
        for h in (13, 14, 15, 16, 17, 18, 1, 2):
            self.assertTrue(
                is_active(m, h, self.positions),
                f'hole {h} was played before he walked in — a hole-number '
                f'test drops him from it')

    def test_holes_he_MISSED_keep_him_out(self):
        m = self._wd(self.ps[1], 2)
        for h in range(3, 13):
            self.assertFalse(is_active(m, h, self.positions),
                             f'he was gone by hole {h}')

    def test_nobody_withdrawn_is_in_on_every_hole(self):
        m = self.fs.memberships.first()
        self.assertTrue(all(is_active(m, h, self.positions)
                            for h in self.order))

    def test_a_withdrawal_on_the_LAST_hole_leaves_him_in_all_round(self):
        m = self._wd(self.ps[1], 12)     # 12 is the last hole in this order
        self.assertTrue(all(is_active(m, h, self.positions)
                            for h in self.order))

    def test_the_roster_and_the_count_agree(self):
        self._wd(self.ps[1], 2)
        for h in (18, 5):
            self.assertEqual(
                len(active_pids(self.members, h, self.positions)),
                active_count(self.members, h, self.positions))


class KilledHoleTests(_Shotgun):
    def test_the_abandoned_hole_is_the_next_one_PLAYED(self):
        self._wd(self.ps[1], 2, killed=True)
        self.assertEqual(
            killed_holes(self.members, self.order, self.positions), {3})

    def test_a_withdrawal_at_the_TURN_kills_hole_1(self):
        """The case `withdrew_after_hole + 1` got silently wrong: it gave 19,
        which Skins discarded as out of range — so the hole the group actually
        abandoned was scored as though they had played it."""
        self._wd(self.ps[1], 18, killed=True)
        self.assertEqual(
            killed_holes(self.members, self.order, self.positions), {1},
            'off the 13th the hole after the 18th is the 1st')

    def test_nothing_is_killed_on_the_GROUP_S_last_hole(self):
        self._wd(self.ps[1], 12, killed=True)
        self.assertEqual(
            killed_holes(self.members, self.order, self.positions), set())

    def test_no_kill_asked_means_no_kill(self):
        self._wd(self.ps[1], 2, killed=False)
        self.assertEqual(
            killed_holes(self.members, self.order, self.positions), set())


class StartingOnTheFirstTests(_Shotgun):
    """The ordinary round: position and number coincide, so nothing moved."""

    start = 1

    def test_it_behaves_exactly_as_the_hole_number_rule_did(self):
        m = self._wd(self.ps[1], 9, killed=True)
        for h in range(1, 10):
            self.assertTrue(is_active(m, h, self.positions))
        for h in range(10, 19):
            self.assertFalse(is_active(m, h, self.positions))
        self.assertEqual(
            killed_holes(self.members, self.order, self.positions), {10})


class TheGamesReadItTests(_Shotgun):
    """**Each game's own entry point, off a shotgun.**

    The tests above pin the rule; these pin that the games USE it. Without
    them the module could be correct and all three games could still be
    comparing hole numbers privately, which is exactly the state this
    replaced — and every existing withdrawal test in the repo starts on the
    1st, where the two rules give identical answers.
    """

    def test_skins_segments_follow_the_play_order(self):
        from services.skins import _skins_withdrawal_plan
        self._wd(self.ps[1], 2)     # played 13-18 and 1-2, then walked in
        plan = _skins_withdrawal_plan(self.members, self.fs)

        # Two constant-roster runs: four men for the eight holes he played,
        # three for the ten he missed.
        self.assertEqual([len(s['roster']) for s in plan['segments']], [4, 3])
        self.assertEqual(plan['segments'][0]['holes'],
                         [13, 14, 15, 16, 17, 18, 1, 2],
                         'the run he played is consecutive in PLAY order, and '
                         '18 -> 1 is not consecutive in numbers')
        self.assertEqual(plan['segments'][1]['holes'], list(range(3, 13)))
        # Every hole still belongs to a segment — none evaporated.
        self.assertEqual(plan['eligible'], set(self.order))

    def test_skins_kills_the_next_hole_PLAYED(self):
        from services.skins import _skins_withdrawal_plan
        self._wd(self.ps[1], 18, killed=True)
        plan = _skins_withdrawal_plan(self.members, self.fs)
        self.assertEqual(plan['killed_holes'], {1})
        self.assertNotIn(1, plan['eligible'],
                         'the abandoned hole must not be contested')

    def test_forty_balls_counts_the_right_holes(self):
        from services.forty_balls import active_on_hole
        self._wd(self.ps[1], 2)
        for h in (13, 18, 1, 2):
            self.assertEqual(active_on_hole(self.fs, h), 4,
                             f'all four played hole {h}')
        for h in (3, 12):
            self.assertEqual(active_on_hole(self.fs, h), 3,
                             f'only three were left for hole {h}')

    def test_spots_roster_is_right_per_hole(self):
        from services.spots import _active_roster_by_hole
        self._wd(self.ps[1], 2)
        roster = _active_roster_by_hole(self.members, self.fs)
        self.assertEqual(len(roster[18]), 4, 'he played the 18th')
        self.assertEqual(len(roster[3]), 3, 'he had gone by the 3rd')
        self.assertNotIn(self.ps[1].id, roster[3])
        self.assertIn(self.ps[1].id, roster[18])

    def test_triple_cup_reads_the_same_rule(self):
        from services.triple_cup import _active_on_hole, _play_positions
        from services.triple_cup import setup_triple_cup
        from games.models import TripleCupGame
        setup_triple_cup(
            self.fs,
            team1_ids=[self.ps[0].id, self.ps[1].id],
            team2_ids=[self.ps[2].id, self.ps[3].id])
        game = TripleCupGame.objects.get(foursome=self.fs)
        self._wd(self.ps[1], 2)
        mbp = {m.player_id: m for m in self.members}
        pos = _play_positions(game)
        pids = [self.ps[0].id, self.ps[1].id]
        self.assertIn(self.ps[1].id, _active_on_hole(pids, mbp, 18, pos))
        self.assertNotIn(self.ps[1].id, _active_on_hole(pids, mbp, 3, pos))
