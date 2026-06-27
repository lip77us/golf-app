"""Unit tests for the phantom algorithms (no DB needed).

Step 1 of the fourball-phantom redesign: the cross-foursome phantom now keeps
each donor's playing handicap in its config so the per-hole strokes-off recompute
can score every fourball hole as a real 4-some including that hole's donor.
"""
from django.test import SimpleTestCase

from scoring.phantom import CrossFoursomeRotation, CROSS_FOURSOME_ALGORITHM_ID
from services.triple_cup import _whs_so_net_index
from services.nassau import _apply_per_hole_donor_so


class CrossFoursomeDonorHandicapTests(SimpleTestCase):
    algo = CrossFoursomeRotation()

    BASE = {
        'rotation': [101, 102, 103],
        'donor_names': {'101': 'A', '102': 'B', '103': 'C'},
        'donor_handicaps': {'101': 5, '102': 12, '103': 20},
    }

    def test_donor_handicap_follows_rotation_and_cycles(self):
        a, c = self.algo, self.BASE
        # hole assignment = rotation[(hole-1) % 3]
        self.assertEqual(a.get_source_player_id(1, c), 101)
        self.assertEqual(a.donor_handicap(1, c), 5)
        self.assertEqual(a.donor_handicap(2, c), 12)
        self.assertEqual(a.donor_handicap(3, c), 20)
        self.assertEqual(a.donor_handicap(4, c), 5)    # cycles back
        self.assertEqual(a.donor_handicap(6, c), 20)

    def test_tolerates_int_keys(self):
        # JSON round-trips keys to strings, but in-memory configs may use ints.
        c = {'rotation': [7], 'donor_handicaps': {7: 9}}
        self.assertEqual(self.algo.donor_handicap(1, c), 9)

    def test_none_when_unconfigured(self):
        a = self.algo
        self.assertIsNone(a.donor_handicap(1, {'rotation': []}))
        self.assertIsNone(a.donor_handicap(1, {'rotation': [1], 'donor_handicaps': {}}))

    def test_zero_handicap_donor_is_not_treated_as_missing(self):
        # A scratch donor (hcp 0) must return 0, not None.
        c = {'rotation': [5], 'donor_handicaps': {'5': 0}}
        self.assertEqual(self.algo.donor_handicap(1, c), 0)


# --- Step 2: per-hole donor strokes-off in the fourball net index -------------

class _Player:
    def __init__(self, pid, is_phantom=False):
        self.id, self.is_phantom = pid, is_phantom


class _Tee:
    """stroke_index == hole number, so SO=n gives strokes on holes 1..n."""
    def hole(self, h):
        return {'stroke_index': h}


class _Member:
    def __init__(self, pid, hcp, is_phantom=False, algo=None, cfg=None):
        self.player_id = pid
        self.player = _Player(pid, is_phantom)
        self.playing_handicap = hcp
        self.tee = _Tee()
        self.tee_id = 1
        self.phantom_algorithm = algo
        self.phantom_config = cfg


class _Game:
    net_percent = 100


class FourballPerHoleDonorSOTests(SimpleTestCase):
    """Each fourball hole is scored as a real 4-some {solo, that hole's donor,
    opp1, opp2}: low = min(real low, donor index); everyone (incl. the phantom
    at the donor's index) gets (index − low) strokes."""

    SOLO, OPP1, OPP2, PHANTOM = 1, 2, 3, 99   # hcps 10 / 6 / 14 / (donor-driven)

    def _members(self, rotation, donor_handicaps):
        cfg = {'rotation': rotation, 'donor_handicaps': donor_handicaps}
        return {
            self.SOLO:    _Member(self.SOLO, 10),
            self.OPP1:    _Member(self.OPP1, 6),
            self.OPP2:    _Member(self.OPP2, 14),
            self.PHANTOM: _Member(self.PHANTOM, 0, is_phantom=True,
                                  algo=CROSS_FOURSOME_ALGORITHM_ID, cfg=cfg),
        }

    def _strokes(self, rotation, donor_handicaps, holes):
        """Return {pid: {hole: strokes}} by diffing gross (all 5s) from net."""
        members = self._members(rotation, donor_handicaps)
        gross = {pid: {h: 5 for h in holes} for pid in members}
        net = _whs_so_net_index(
            None, _Game(), members, gross,
            include_phantom=True, fourball_holes=set(holes),
        )
        return {pid: {h: 5 - net[pid][h] for h in holes} for pid in net}

    def test_donor_is_the_low_gives_real_players_extra_strokes(self):
        # Single donor at hcp 2 (below real low 6) → low collapses to 2.
        # solo SO 8, opp1 SO 4, opp2 SO 12, phantom SO 0.
        s = self._strokes([201], {'201': 2}, holes=[1, 5])
        self.assertEqual(s[self.SOLO][1], 1)     # SO8, SI1 → stroke
        self.assertEqual(s[self.SOLO][5], 1)     # SO8, SI5 → stroke
        self.assertEqual(s[self.OPP1][1], 1)     # SO4, SI1 → stroke
        self.assertEqual(s[self.OPP1][5], 0)     # SO4, SI5 → none
        self.assertEqual(s[self.OPP2][5], 1)     # SO12, SI5 → stroke
        self.assertEqual(s[self.PHANTOM][1], 0)  # donor is the low → 0 strokes
        self.assertEqual(s[self.PHANTOM][5], 0)

    def test_real_player_strokes_change_as_donor_rotates(self):
        # Hole 1 donor = 201 (hcp 2, below real low) → low 2.
        # Hole 2 donor = 202 (hcp 9, above real low) → low stays 6.
        s = self._strokes([201, 202], {'201': 2, '202': 9}, holes=[1, 2])
        # opp1 (hcp 6): SO 4 on hole1 (low 2) → stroke; SO 0 on hole2 (low 6) → none.
        self.assertEqual(s[self.OPP1][1], 1)
        self.assertEqual(s[self.OPP1][2], 0)
        # solo (hcp 10): SO 8 hole1 → stroke; SO 4 hole2 (SI2≤4) → stroke.
        self.assertEqual(s[self.SOLO][1], 1)
        self.assertEqual(s[self.SOLO][2], 1)
        # phantom plays as the donor: SO 0 hole1 → none; SO 3 hole2 (SI2≤3) → stroke.
        self.assertEqual(s[self.PHANTOM][1], 0)
        self.assertEqual(s[self.PHANTOM][2], 1)


class CupFourballDonorSOParityTests(SimpleTestCase):
    """The cup-Nassau Four Ball helper must produce the SAME per-hole strokes
    as the Triple Cup path (they share the rule; a shared helper is future
    work, so this guards against drift)."""

    def test_nassau_helper_matches_triple_cup(self):
        solo = _Member(1, 10)
        opp1 = _Member(2, 6)
        opp2 = _Member(3, 14)
        cfg = {'rotation': [201, 202], 'donor_handicaps': {'201': 2, '202': 9}}
        phantom = _Member(99, 0, is_phantom=True,
                          algo=CROSS_FOURSOME_ALGORITHM_ID, cfg=cfg)
        score_index = {pid: {1: 5, 2: 5} for pid in (1, 2, 3, 99)}

        _apply_per_hole_donor_so(score_index, [solo, opp1, opp2], phantom, 100)
        strokes = {pid: {h: 5 - score_index[pid][h] for h in (1, 2)}
                   for pid in score_index}

        # Identical to FourballPerHoleDonorSOTests.test_real_player_strokes_*:
        self.assertEqual(strokes[1],  {1: 1, 2: 1})   # solo
        self.assertEqual(strokes[2],  {1: 1, 2: 0})   # opp1 (loses stroke hole2)
        self.assertEqual(strokes[3],  {1: 1, 2: 1})   # opp2
        self.assertEqual(strokes[99], {1: 0, 2: 1})   # phantom plays as donor
