"""
scoring/tests/test_combo_tees.py
--------------------------------
Deriving which tee a combo plays on each hole.

The data never says. A combo is one row in the dropdown with one rating and one
slope, so the answer has to be worked out from the yardages — and the whole
design rests on doing that ONCE, at setup, so the indicator is present on all
eighteen holes or on none. A per-hole lookup that can come back empty is the
failure this is built to avoid.
"""
from django.test import TestCase

from core.models import Course, Tee
from services.combo_tees import (is_combo, resolve_parents, tee_map,
                                 tee_name_for_hole, unsupported_reason)
from ._helpers import _test_account, make_course


def _holes(yards: list, par=4, si_from=1):
    return [{'number': i + 1, 'par': par, 'stroke_index': i + 1,
             'yards': y} for i, y in enumerate(yards)]


def _tee(course, name, yards, sex='M', priority=0):
    return Tee.objects.create(
        course=course, tee_name=name, sex=sex, slope=113,
        course_rating=72.0, par=72, sort_priority=priority,
        holes=_holes(yards))


BLUE  = [400] * 9 + [420] * 9          # 7380
WHITE = [360] * 9 + [380] * 9          # 6660
RED   = [300] * 9 + [320] * 9          # 5580


class _Base(TestCase):
    def setUp(self):
        self.course = make_course('Combo Links')
        self.blue  = _tee(self.course, 'Blue',  BLUE,  priority=1)
        self.white = _tee(self.course, 'White', WHITE, priority=2)
        self.red   = _tee(self.course, 'Red',   RED,   priority=3)

    def _combo(self, name, picks):
        """picks: one of 'B'/'W'/'R' per hole."""
        src = {'B': BLUE, 'W': WHITE, 'R': RED}
        return _tee(self.course, name,
                    [src[p][i] for i, p in enumerate(picks)])


class DetectionTests(_Base):

    def test_the_name_is_the_only_signal(self):
        """There is no flag for it in the data."""
        self.assertTrue(is_combo(self._combo('Blue/White Combo', 'BW' * 9)))
        self.assertTrue(is_combo(self._combo('combo', 'BW' * 9)))
        self.assertFalse(is_combo(self.blue))

    def test_an_ordinary_tee_resolves_to_nothing(self):
        self.assertIsNone(resolve_parents(self.blue))
        self.assertEqual(tee_map(self.blue), {})


class ResolutionTests(_Base):

    def test_it_finds_the_pair_and_names_every_hole(self):
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertEqual({t.tee_name for t in resolve_parents(combo)},
                         {'Blue', 'White'})
        m = tee_map(combo)
        self.assertEqual(len(m), 18)
        self.assertEqual(m[1], 'Blue')
        self.assertEqual(m[2], 'White')

    def test_the_parents_are_not_parsed_from_the_name(self):
        """Against the real database, matching alone resolves names that do not
        parse at all — `B/W Combo` (initials) and a bare `Combo`. A parse step
        would only add a way to disagree with the check that has to follow it."""
        combo = self._combo('Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertEqual({t.tee_name for t in resolve_parents(combo)},
                         {'Blue', 'White'})
        self.assertEqual(len(tee_map(combo)), 18)

    def test_three_parents_are_allowed(self):
        """The spec says PAIR throughout; three real combos in the database
        need three sets, and the guarantee is unchanged by it — a fixed set of
        size N either accounts for every hole or the feature turns off."""
        combo = self._combo('Team Match Combo', 'BWRBWRBWRBWRBWRBWR')
        names = {t.tee_name for t in resolve_parents(combo)}
        self.assertEqual(names, {'Blue', 'White', 'Red'})
        self.assertEqual(len(tee_map(combo)), 18)

    def test_the_smallest_set_wins(self):
        """A two-tee combo must never be described as a three-tee one."""
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertEqual(len(resolve_parents(combo)), 2)

    def test_a_spare_parent_is_refused(self):
        """Every member has to EARN its place. A set that still covers the card
        with one member dropped is really the smaller set, and naming the spare
        would put a tee on the chip the combo does not use."""
        # Red is never used, but Blue+White+Red would still cover the card.
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertNotIn('Red', {t.tee_name for t in resolve_parents(combo)})


class TieTests(_Base):
    """Both parents often play a short par 3 from the same spot."""

    def test_identical_yardage_takes_the_LONGER_parent(self):
        """Where the yardage is the same the shot is identical, so there is
        nothing to get wrong. Longer rather than first-named because name order
        carries no meaning — "Blue/White" and "White/Blue" are the same tees —
        while total yardage is a property of the tees themselves."""
        # Two sets that agree on hole 1 and differ elsewhere; Tips is longer.
        tips = _tee(self.course, 'Tips', [BLUE[0]] + [500] * 17, priority=0)
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertEqual(
            tee_name_for_hole(combo, 1, parents=[self.blue, tips]), 'Tips')

    def test_the_order_the_parents_arrive_in_does_not_matter(self):
        tips = _tee(self.course, 'Tips', [BLUE[0]] + [500] * 17, priority=0)
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertEqual(tee_name_for_hole(combo, 1, parents=[tips, self.blue]),
                         tee_name_for_hole(combo, 1, parents=[self.blue, tips]))

    def test_and_it_gives_the_same_answer_every_time(self):
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        first = tee_map(combo)
        for _ in range(3):
            self.assertEqual(tee_map(combo), first)


class UnsupportedTests(_Base):

    def test_one_bad_hole_turns_the_whole_round_off(self):
        """One decision up front with one clear failure, instead of eighteen
        chances to quietly come back empty."""
        yards = [BLUE[i] for i in range(18)]
        yards[8] = 517                       # matches nothing
        combo = _tee(self.course, 'Blue/White Combo', yards)
        self.assertIsNone(resolve_parents(combo))
        self.assertEqual(tee_map(combo), {})

    def test_the_reason_names_the_hole_and_what_it_was_compared_against(self):
        """For the log, never for a golfer: the likely cause is a course-data
        problem worth fixing once, not something to work around eighteen
        times."""
        yards = [BLUE[i] for i in range(18)]
        yards[8] = 517
        combo = _tee(self.course, 'Blue/White Combo', yards)
        why = unsupported_reason(combo)
        self.assertIn('hole 9', why)
        self.assertIn('517', why)
        self.assertIn('Blue=', why)

    def test_a_course_with_nothing_to_blend_says_so(self):
        solo = make_course('Lonely Links')
        only = _tee(solo, 'White', WHITE)
        combo = _tee(solo, 'Combo', WHITE)
        del only
        self.assertIsNone(resolve_parents(combo))
        self.assertIn('fewer than two', unsupported_reason(combo))

    def test_a_supported_combo_has_no_reason(self):
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertEqual(unsupported_reason(combo), '')


class ScopeTests(_Base):

    def test_parents_are_the_same_sex_only(self):
        """A set only ever blends within its own card."""
        _tee(self.course, 'Blue', [1] * 18, sex='W')
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertTrue(all(t.sex == 'M' for t in resolve_parents(combo)))

    def test_a_superseded_tee_is_not_a_parent(self):
        """It is a previous version of a parent, not a different set."""
        old = _tee(self.course, 'Blue (old)', [999] * 18, priority=8)
        old.superseded_by = self.blue
        old.save(update_fields=['superseded_by'])
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertNotIn('Blue (old)',
                         {t.tee_name for t in resolve_parents(combo)})

    def test_a_combo_is_never_another_combos_parent(self):
        self._combo('Other Combo', 'BBBBBBBBBWWWWWWWWW')
        combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.assertTrue(all(not is_combo(t) for t in resolve_parents(combo)))


class LockScreenTests(_Base):
    """`TEE · WHITE` on the card — a third element on a surface capped at two.

    It earns the space by appearing ONLY for a golfer on a combo, so for every
    other reader the two-item rule holds exactly as specified.
    """

    def setUp(self):
        super().setUp()
        from scoring.tests._helpers import make_foursome, make_round
        self.combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.round = make_round(self.course)
        self.fs = make_foursome(self.round, [('Ann', 10), ('Ben', 10)],
                                tee=self.white)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        ann = self.fs.memberships.get(player_id=self.pid['Ann'])
        ann.tee = self.combo
        ann.save(update_fields=['tee'])

    def _tee(self, who, hole):
        from services.live_activity_registry import combo_tee
        return combo_tee(self.fs, self.pid[who], hole)

    def test_the_combo_golfer_gets_his_tee(self):
        self.assertEqual(self._tee('Ann', 1), 'Blue')
        self.assertEqual(self._tee('Ann', 2), 'White')

    def test_nobody_else_does(self):
        """Ben is on an ordinary White tee — the row is absent for him, which
        is what keeps the card at two items for every reader who is not on a
        combo."""
        self.assertEqual(self._tee('Ben', 1), '')

    def test_a_watcher_gets_nothing(self):
        from services.live_activity_registry import combo_tee
        self.assertEqual(combo_tee(self.fs, None, 1), '')

    def test_a_finished_round_has_no_hole_and_so_no_tee(self):
        from services.live_activity_registry import combo_tee
        self.assertEqual(combo_tee(self.fs, self.pid['Ann'], None), '')

    def test_it_is_there_on_every_hole_or_none(self):
        """The parent set is fixed at setup, so the row never appears and
        disappears mid-round."""
        names = [self._tee('Ann', h) for h in range(1, 19)]
        self.assertTrue(all(n for n in names))
        self.assertEqual(set(names), {'Blue', 'White'})

    def test_an_unsupported_combo_is_off_for_the_whole_round(self):
        yards = [BLUE[i] for i in range(18)]
        yards[8] = 517
        broken = _tee(self.course, 'Blue/White Combo II', yards)
        ann = self.fs.memberships.get(player_id=self.pid['Ann'])
        ann.tee = broken
        ann.save(update_fields=['tee'])
        self.assertEqual([self._tee('Ann', h) for h in range(1, 19)],
                         [''] * 18)


class SerializerTests(_Base):
    """Score entry needs hole -> tee for the viewing golfer's own row."""

    def setUp(self):
        super().setUp()
        from scoring.tests._helpers import make_foursome, make_round
        self.combo = self._combo('Blue/White Combo', 'BWBWBWBWBWBWBWBWBW')
        self.round = make_round(self.course)
        self.fs = make_foursome(self.round, [('Ann', 10), ('Ben', 10)],
                                tee=self.white)
        ann = self.fs.memberships.get(player__name='Ann')
        ann.tee = self.combo
        ann.save(update_fields=['tee'])

    def _rows(self):
        from api.serializers import MembershipSerializer
        return {m['player']['name']: m['combo_tee_by_hole']
                for m in MembershipSerializer(
                    self.fs.memberships.select_related('player', 'tee'),
                    many=True).data}

    def test_the_combo_golfer_carries_the_whole_map(self):
        rows = self._rows()
        self.assertEqual(len(rows['Ann']), 18)
        self.assertEqual(rows['Ann']['1'], 'Blue')
        self.assertEqual(rows['Ann']['2'], 'White')

    def test_an_ordinary_tee_carries_nothing(self):
        """Only the combo golfer sees it, so only he is sent it."""
        self.assertEqual(self._rows()['Ben'], {})

    def test_the_keys_are_strings_because_JSON(self):
        self.assertTrue(all(isinstance(k, str) for k in self._rows()['Ann']))
