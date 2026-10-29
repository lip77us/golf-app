"""The two rules that answered one question, and the gap between them.

Reported from the course (round 489, 26 Oct 2026): a Sixes round that was
fully scored warned *"1 hole still has no score"*, and the golfer completed
anyway — the right call, which he should not have had to guess at.
"""

from datetime import date

from rest_framework.test import APITestCase

from api.serializers import RoundSerializer
from api.views import RoundCompleteView
from scoring.models import HoleScore
from scoring.tests._helpers import make_foursome, make_round, make_tee


class HoleCoverageIsTheGateTests(APITestCase):
    """`all_holes_scored` counts hole COVERAGE, and that stays."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course)
        # `make_round` leaves `date` at the model default, which is a
        # datetime; the serializer refuses to coerce one to a date.
        self.round.date = date.today()
        self.round.save(update_fields=['date'])
        self.fs = make_foursome(
            self.round,
            [('A', 8), ('B', 12), ('C', 16), ('D', 20)],
            tee=self.tee,
        )
        self.players = [m.player for m in self.fs.memberships.all()]

    def _score(self, holes, players=None):
        for h in holes:
            for p in (players or self.players):
                HoleScore.objects.update_or_create(
                    foursome=self.fs, player=p, hole_number=h,
                    defaults={'gross_score': 4})

    def test_a_fully_scored_round_is_done_and_warns_about_nothing(self):
        self._score(range(1, 19))
        d = RoundSerializer(self.round).data
        self.assertTrue(d['all_holes_scored'])
        self.assertEqual(d['holes_remaining'], 0)
        self.assertEqual(d['holes_unscored'], [])
        self.assertEqual(d['holes_awaiting'], [])

    def test_three_of_four_COMPLETES_but_is_now_REPORTED(self):
        """The gate is unchanged; the warning is the new part.

        Hole coverage has to stay lenient: an alt-shot hole only ever has
        one partner posting, so a per-golfer gate would make every Triple
        Cup foursomes round permanently unfinishable.
        """
        self._score(range(1, 19))
        HoleScore.objects.filter(foursome=self.fs, player=self.players[0],
                                 hole_number=7).delete()
        d = RoundSerializer(self.round).data
        # The round still completes — that is deliberate and unchanged.
        self.assertTrue(d['all_holes_scored'])
        self.assertEqual(d['holes_remaining'], 0)
        self.assertEqual(d['holes_unscored'], [])
        # ...and the gap is now reported, which is what was missing.
        self.assertEqual(d['holes_awaiting'], [7])

    def test_a_hole_NOBODY_played_is_unscored_not_awaiting(self):
        """The two kinds are never the same hole, or the dialog says both."""
        self._score(range(1, 18))
        d = RoundSerializer(self.round).data
        self.assertEqual(d['holes_unscored'], [18])
        self.assertNotIn(18, d['holes_awaiting'])
        self.assertFalse(d['all_holes_scored'])
        self.assertEqual(d['holes_remaining'], 1)

    def test_holes_unscored_is_holes_remaining_as_a_list(self):
        """A count cannot be named in a dialog, which is the whole point."""
        self._score([1, 2, 3])
        d = RoundSerializer(self.round).data
        self.assertEqual(len(d['holes_unscored']), d['holes_remaining'])
        self.assertEqual(d['holes_unscored'], list(range(4, 19)))

    def test_a_withdrawn_golfer_is_not_awaited(self):
        """He is not missing a score; he went home."""
        m = self.fs.memberships.order_by('id').first()
        m.withdrew_after_hole = 9
        m.save(update_fields=['withdrew_after_hole'])
        self._score(range(1, 10))
        self._score(range(10, 19), players=self.players[1:])
        d = RoundSerializer(self.round).data
        self.assertEqual(d['holes_awaiting'], [],
                         'a withdrawal is not a missing score')
        self.assertTrue(d['all_holes_scored'])

    def test_a_phantom_is_never_awaited(self):
        """It has no card of its own to be missing from."""
        self._score(range(1, 19))
        d = RoundSerializer(self.round).data
        self.assertEqual(d['holes_awaiting'], [])

    def test_the_gate_and_the_warning_are_asked_of_the_same_holes(self):
        """Both read `_expected_holes`, so a partial round cannot have one
        of them counting a hole the other does not."""
        self._score(range(1, 19))
        HoleScore.objects.filter(foursome=self.fs, player=self.players[0],
                                 hole_number=7).delete()
        expected = RoundCompleteView._expected_holes(self.fs)
        d = RoundSerializer(self.round).data
        for h in d['holes_awaiting'] + d['holes_unscored']:
            self.assertIn(h, expected)
