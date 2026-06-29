"""
api/test_eighteen_hole_match.py
-------------------------------
`_round_is_eighteen_hole_match` distinguishes a (singles) 18-Hole Match from the
other Nassau-engine games it shares storage with:

  - 18-Hole Match  = Overall-only Nassau, 1-v-1
  - Singles Nassau = front + back + overall, 1-v-1   (NOT a match)
  - Fourball       = Overall-only, 2-v-2             (NOT a match)

The list / shared / scoring feeds use this to label the round "18-Hole Match"
instead of the generic "Nassau".
"""

from django.test import TestCase

from services.nassau import setup_nassau
from scoring.tests._helpers import make_tee, make_round, make_foursome
from api.views import _round_is_eighteen_hole_match


class EighteenHoleMatchDetectionTests(TestCase):
    def _round_fs(self, players, *, active_games=('nassau',)):
        tee = make_tee()
        rnd = make_round(tee.course, active_games=list(active_games))
        fs = make_foursome(rnd, players, tee=tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        return rnd, fs, pid

    def test_singles_overall_only_is_a_match(self):
        rnd, fs, pid = self._round_fs([('A', 8), ('B', 12)])
        setup_nassau(fs, [pid['A']], [pid['B']],
                     play_front=False, play_back=False, play_overall=True)
        self.assertTrue(_round_is_eighteen_hole_match(rnd, fs))

    def test_two_v_two_overall_only_is_fourball_not_a_match(self):
        rnd, fs, pid = self._round_fs(
            [('A', 8), ('B', 12), ('C', 16), ('D', 20)])
        setup_nassau(fs, [pid['A'], pid['B']], [pid['C'], pid['D']],
                     play_front=False, play_back=False, play_overall=True)
        self.assertFalse(_round_is_eighteen_hole_match(rnd, fs))

    def test_singles_full_nassau_is_not_a_match(self):
        rnd, fs, pid = self._round_fs([('A', 8), ('B', 12)])
        setup_nassau(fs, [pid['A']], [pid['B']],
                     play_front=True, play_back=True, play_overall=True)
        self.assertFalse(_round_is_eighteen_hole_match(rnd, fs))

    def test_no_nassau_is_not_a_match(self):
        rnd, fs, _ = self._round_fs([('A', 8), ('B', 12)],
                                    active_games=('skins',))
        self.assertFalse(_round_is_eighteen_hole_match(rnd, fs))
