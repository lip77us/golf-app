"""
scoring/tests/test_phantom_propagate.py
---------------------------------------
propagate_phantom_score mirrors a cross-foursome donor's gross onto the phantom
in ANOTHER foursome, and now RETURNS the affected phantom foursomes so the score
view can recalc their games — otherwise a (possibly retroactive) donor edit/clear
leaves that foursome's stored result stale.
"""
from decimal import Decimal

from django.test import TestCase

from scoring.models import HoleScore
from scoring.phantom import CROSS_FOURSOME_ALGORITHM_ID, propagate_phantom_score
from tournament.models import Foursome, FoursomeMembership

from ._helpers import make_player, make_round, make_tee


class PropagatePhantomReturnTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['nassau'])
        self.fsA   = Foursome.objects.create(round=self.round, group_number=1)
        self.fsB   = Foursome.objects.create(round=self.round, group_number=2)

        self.donor = make_player('Donor', 5)
        FoursomeMembership.objects.create(
            foursome=self.fsA, player=self.donor, tee=self.tee,
            course_handicap=5, playing_handicap=5)

        # Phantom in foursome B, fed by the donor via cross-foursome rotation.
        self.phantom = make_player('Phantom', 0, is_phantom=True)
        FoursomeMembership.objects.create(
            foursome=self.fsB, player=self.phantom, tee=self.tee,
            course_handicap=0, playing_handicap=0,
            phantom_algorithm=CROSS_FOURSOME_ALGORITHM_ID,
            phantom_config={'rotation': [self.donor.id]})

    def _phantom_gross(self):
        hs = HoleScore.objects.filter(
            foursome=self.fsB, player=self.phantom, hole_number=1).first()
        return hs.gross_score if hs else None

    def test_write_returns_affected_foursome(self):
        touched = propagate_phantom_score(self.round, 1, self.donor.id, 4)
        self.assertEqual([fs.id for fs in touched], [self.fsB.id])
        self.assertEqual(self._phantom_gross(), 4)

    def test_edit_updates_phantom_and_still_returns_foursome(self):
        propagate_phantom_score(self.round, 1, self.donor.id, 4)
        touched = propagate_phantom_score(self.round, 1, self.donor.id, 6)
        self.assertEqual([fs.id for fs in touched], [self.fsB.id])
        self.assertEqual(self._phantom_gross(), 6)          # retroactive edit lands

    def test_clear_deletes_phantom_and_still_returns_foursome(self):
        propagate_phantom_score(self.round, 1, self.donor.id, 4)
        touched = propagate_phantom_score(self.round, 1, self.donor.id, None)
        self.assertEqual([fs.id for fs in touched], [self.fsB.id])
        self.assertIsNone(self._phantom_gross())            # phantom row cleared

    def test_non_donor_change_affects_nothing(self):
        other = make_player('Other', 8)
        FoursomeMembership.objects.create(
            foursome=self.fsA, player=other, tee=self.tee,
            course_handicap=8, playing_handicap=8)
        self.assertEqual(propagate_phantom_score(self.round, 1, other.id, 4), [])
