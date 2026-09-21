"""
scoring/tests/test_team_tee.py
------------------------------
Which tee a TEAM plays, and whether a one-ball game counts as started.

Both came out of the Heart Health Scramble at Tilden, where the women's par is
71 and the men's 70.  Two teams each had one woman; they played par 71 while
the all-men team played par 70, because a team's par was taken from whichever
golfer had been entered first.
"""
from django.test import TestCase

from services.team_play_state import hole_data
from ._helpers import DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee


def _women_holes():
    """DEFAULT_HOLES with one extra stroke of par and the indexes reshuffled —
    the shape of a real women's tee: a par 4 that is a 5, different hardest
    holes."""
    holes = [dict(h) for h in DEFAULT_HOLES]
    holes[0]['par'] += 1                    # hole 1: a par 4 plays as a 5
    for h in holes:
        h['stroke_index'] = 19 - h['stroke_index']
    return holes


class TeamTeeTests(TestCase):

    def setUp(self):
        course = make_course()
        self.men   = make_tee(course, tee_name='White', par=72)
        self.women = make_tee(course, tee_name='Red',   par=73,
                              holes=_women_holes())
        self.round = make_round(course)
        self._groups = 0

    def _team(self, tees):
        """A foursome whose members are on `tees`, in that ENTRY order."""
        self._groups += 1
        fs = make_foursome(self.round,
                           [(f'G{self._groups}-{i}', 10)
                            for i in range(len(tees))],
                           tee=self.men, group_number=self._groups)
        for m, tee in zip(fs.memberships.order_by('id'), tees):
            m.tee = tee
            m.save(update_fields=['tee'])
        return fs

    def _par(self, fs):
        return sum(h['par'] for h in hole_data(fs))

    # -- the case as it happened -------------------------------------------

    def test_three_men_and_one_woman_play_the_mens_tee(self):
        fs = self._team([self.men, self.men, self.men, self.women])
        self.assertEqual(self._par(fs), 72)

    def test_even_when_the_woman_was_entered_first(self):
        """The bug exactly: entry order decided the team's tee."""
        fs = self._team([self.women, self.men, self.men, self.men])
        self.assertEqual(self._par(fs), 72)

    def test_the_stroke_indexes_come_with_the_tee(self):
        """Par and SI are one decision. A team must not play the men's par on
        the women's indexes."""
        fs = self._team([self.women, self.men, self.men, self.men])
        by_hole = {h['number']: h for h in hole_data(fs)}
        self.assertEqual(by_hole[1]['stroke_index'], 7)     # the men's SI

    # -- the majority rule generally ---------------------------------------

    def test_three_women_and_one_man_play_the_womens_tee(self):
        fs = self._team([self.men, self.women, self.women, self.women])
        self.assertEqual(self._par(fs), 73)

    def test_a_tie_takes_the_lower_par(self):
        """Two and two — the harder standard, so a team cannot lower the bar
        by who it adds."""
        fs = self._team([self.women, self.women, self.men, self.men])
        self.assertEqual(self._par(fs), 72)

    def test_a_team_all_on_one_tee_is_unchanged(self):
        self.assertEqual(self._par(self._team([self.men] * 4)), 72)
        self.assertEqual(self._par(self._team([self.women] * 4)), 73)


class OneBallStartedTests(TestCase):
    """A scramble records one team score a hole and no per-golfer HoleScore, so
    the hub read it as unstarted all round and said "Start Match"."""

    def setUp(self):
        tee = make_tee()
        self.round = make_round(tee.course)
        self.fs = make_foursome(self.round, [('A', 10), ('B', 10)], tee=tee)

    def _started(self):
        from api.serializers import FoursomeSerializer
        return FoursomeSerializer().get_has_any_score(self.fs)

    def test_a_fresh_foursome_has_not_started(self):
        self.assertFalse(self._started())

    def test_a_team_score_means_it_has(self):
        from games.models import TeamHoleScore
        TeamHoleScore.objects.create(foursome=self.fs, hole_number=1,
                                     gross_score=4)
        self.assertTrue(self._started())

    def test_an_empty_team_row_does_not_count(self):
        """A row created for a hole nobody has scored yet is not a start."""
        from games.models import TeamHoleScore
        TeamHoleScore.objects.create(foursome=self.fs, hole_number=1,
                                     gross_score=None)
        self.assertFalse(self._started())
