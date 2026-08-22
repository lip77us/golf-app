"""
scoring/tests/test_team_play_format.py
--------------------------------------
Team Play format rules — ball counts and the drive requirement
(docs/design-review/handoff-team-play/SPEC.md §4, §5; services/team_play.py).

Every worked number in here comes from the packet's own screens, so a change
that moves one of them is a change to the design, not to the code.
"""
from decimal import Decimal

from django.test import TestCase

from services.team_play import (
    ball_count_runs, ball_count_summary, build_rota, drive_penalty_strokes,
    drive_shortfall, drive_windows, pair_on_hole, phantom_cover_on_hole,
    resolve_ball_counts, window_requirement, window_state,
)
from tournament.models import TeamPlayConfig
from ._helpers import DEFAULT_HOLES, make_tournament


def _config(**kw):
    """An unsaved config is enough — none of these functions touch the DB."""
    return TeamPlayConfig(**kw)


# ---------------------------------------------------------------------------
# Ball counts
# ---------------------------------------------------------------------------

class BallCountTests(TestCase):

    def test_fixed_is_the_same_count_all_eighteen(self):
        counts = resolve_ball_counts(_config(ball_count_fixed=2), DEFAULT_HOLES)
        self.assertEqual(set(counts.values()), {2})
        self.assertEqual(len(counts), 18)

    def test_escalating_is_one_two_three_by_sixes(self):
        counts = resolve_ball_counts(
            _config(ball_count_mode=TeamPlayConfig.COUNT_ESCALATING), DEFAULT_HOLES,
        )
        self.assertEqual([counts[h] for h in range(1, 7)],   [1] * 6)
        self.assertEqual([counts[h] for h in range(7, 13)],  [2] * 6)
        self.assertEqual([counts[h] for h in range(13, 19)], [3] * 6)

    def test_par_based_reads_the_card(self):
        """Par 3 = 3 balls, par 4 = 2, par 5 = 1 — the short holes are where a
        team can afford to need everybody."""
        counts = resolve_ball_counts(
            _config(ball_count_mode=TeamPlayConfig.COUNT_PAR_BASED), DEFAULT_HOLES,
        )
        for hole in DEFAULT_HOLES:
            expected = {3: 3, 4: 2, 5: 1}[hole['par']]
            self.assertEqual(counts[hole['number']], expected, hole)

    def test_per_hole_grid_falls_back_to_the_fixed_value(self):
        counts = resolve_ball_counts(
            _config(ball_count_mode=TeamPlayConfig.COUNT_PER_HOLE,
                    ball_counts={'1': 1, '18': 4}, ball_count_fixed=2),
            DEFAULT_HOLES,
        )
        self.assertEqual(counts[1], 1)
        self.assertEqual(counts[18], 4)
        self.assertEqual(counts[9], 2)

    def test_fixed_two_and_escalating_both_total_36(self):
        """The packet's whole argument for showing the total: the same 36 balls
        distributed differently, which makes the choice read as character
        rather than difficulty."""
        fixed = ball_count_summary(
            resolve_ball_counts(_config(ball_count_fixed=2), DEFAULT_HOLES))
        esc = ball_count_summary(resolve_ball_counts(
            _config(ball_count_mode=TeamPlayConfig.COUNT_ESCALATING), DEFAULT_HOLES))

        self.assertEqual(fixed['counted'], 36)
        self.assertEqual(esc['counted'], 36)
        self.assertEqual(fixed['played'], 72)
        self.assertEqual(esc['played'], 72)
        self.assertEqual(fixed['avg_per_hole'], Decimal('2.0'))
        self.assertEqual(esc['avg_per_hole'], Decimal('2.0'))
        # ...and they are NOT the same round.
        self.assertNotEqual(fixed['runs'], esc['runs'])

    def test_preview_collapses_into_runs(self):
        counts = resolve_ball_counts(
            _config(ball_count_mode=TeamPlayConfig.COUNT_ESCALATING), DEFAULT_HOLES)
        self.assertEqual(ball_count_runs(counts),
                         [(1, 6, 1), (7, 12, 2), (13, 18, 3)])

    def test_a_four_ball_hole_is_legal_and_flagged(self):
        """No drop score — one blow-up is the team's."""
        counts = resolve_ball_counts(
            _config(ball_count_mode=TeamPlayConfig.COUNT_PER_HOLE,
                    ball_counts={'18': 4}, ball_count_fixed=2),
            DEFAULT_HOLES,
        )
        self.assertEqual(ball_count_summary(counts)['full_count_holes'], [18])


# ---------------------------------------------------------------------------
# Drives — quotas
# ---------------------------------------------------------------------------

class DriveQuotaTests(TestCase):

    def setUp(self):
        self.per_nine = _config(drive_rule=TeamPlayConfig.DRIVE_PER_NINE,
                                drives_required=1)
        self.four = [101, 102, 103, 104]        # Maiolini, Gunst, Detomasi, Yau
        self.three = [201, 202, 203]            # Bellini, Kwan, Ortega

    def test_per_nine_is_two_independent_windows(self):
        """The front does not carry to the back."""
        self.assertEqual(drive_windows(self.per_nine), [(1, 9), (10, 18)])
        self.assertEqual(
            drive_windows(_config(drive_rule=TeamPlayConfig.DRIVE_PER_18)),
            [(1, 18)],
        )
        self.assertEqual(drive_windows(_config()), [])

    def test_a_quota_shows_its_slack(self):
        """4 required / nine · 9 holes · 5 free — the figure that tells a
        captain whether he can let his long hitter drive the par 5."""
        req = window_requirement(self.per_nine, real_player_count=4)
        self.assertEqual(req['required'], 4)
        self.assertEqual(req['holes'], 9)
        self.assertEqual(req['free'], 5)
        self.assertEqual(req['floating'], 0)

    def test_a_short_team_owes_four_mens_worth(self):
        """Three men at one each would be three drives. A three-man team is not
        really three — it fields a phantom, and the phantom's share rotates."""
        req = window_requirement(self.per_nine, real_player_count=3)
        self.assertEqual(req['required'], 4)
        self.assertEqual(req['floating'], 1)

    def test_the_packet_tracker_two_owed_two_holes_left(self):
        """Pine, thru 7 on the front: Gunst drove h2, Detomasi h5, Maiolini and
        Yau owe one each. Two owed, two holes left — it still works, but only
        just, and the card says so on the 7th rather than the 18th."""
        picks = {2: 102, 5: 103}
        state = window_state(self.per_nine, (1, 9), picks, self.four, thru_hole=7)

        self.assertEqual(state['owed'], 2)
        self.assertEqual(state['holes_left'], 2)
        self.assertTrue(state['tight'])
        self.assertFalse(state['impossible'])

        owes = {g['player_id']: g['owes'] for g in state['golfers']}
        self.assertEqual(owes, {101: 1, 102: 0, 103: 0, 104: 1})

    def test_it_becomes_impossible_one_hole_later(self):
        """The moment owed exceeds holes remaining — not on 18."""
        picks = {2: 102, 5: 103, 8: 102}     # Gunst drives again; nobody new
        state = window_state(self.per_nine, (1, 9), picks, self.four, thru_hole=8)
        self.assertEqual(state['owed'], 2)
        self.assertEqual(state['holes_left'], 1)
        self.assertTrue(state['impossible'])

    def test_the_back_nine_cannot_fix_the_front(self):
        """A man short on the front is already short."""
        picks = {2: 102, 5: 103, 10: 101, 11: 104}
        front = window_state(self.per_nine, (1, 9), picks, self.four, thru_hole=18)
        back  = window_state(self.per_nine, (10, 18), picks, self.four, thru_hole=18)

        self.assertEqual(front['owed'], 2)      # Maiolini and Yau, unfixable
        self.assertEqual(back['owed'], 2)       # Gunst and Detomasi, on the back
        self.assertEqual(drive_shortfall(self.per_nine, picks, self.four), 4)

    def test_a_surplus_drive_covers_the_phantoms_share(self):
        """Any of the three real men can take the phantom's drive — it floats
        rather than being owed by a particular man."""
        picks = {1: 201, 2: 202, 3: 203, 4: 201}   # Bellini drives twice
        state = window_state(self.per_nine, (1, 9), picks, self.three, thru_hole=9)
        self.assertEqual(state['owed'], 0)

    def test_three_men_each_driving_once_still_owe_the_phantom(self):
        picks = {1: 201, 2: 202, 3: 203}
        state = window_state(self.per_nine, (1, 9), picks, self.three, thru_hole=9)
        self.assertEqual(state['owed'], 1)


class DrivePenaltyTests(TestCase):

    def setUp(self):
        self.four = [101, 102, 103, 104]
        self.picks = {2: 102, 5: 103}          # two drives short on the front

    def test_falling_short_costs_nothing_by_default(self):
        cfg = _config(drive_rule=TeamPlayConfig.DRIVE_PER_NINE, drives_required=1)
        self.assertEqual(drive_shortfall(cfg, self.picks, self.four), 6)
        self.assertEqual(drive_penalty_strokes(cfg, self.picks, self.four), 0)

    def test_two_strokes_per_missing_drive_when_opted_in(self):
        cfg = _config(drive_rule=TeamPlayConfig.DRIVE_PER_NINE, drives_required=1,
                      drive_penalty=TeamPlayConfig.PENALTY_TWO_STROKE)
        self.assertEqual(drive_penalty_strokes(cfg, self.picks, self.four), 12)

    def test_a_schedule_has_nothing_to_fall_short_of(self):
        cfg = _config(drive_rule=TeamPlayConfig.DRIVE_ALTERNATING,
                      drive_penalty=TeamPlayConfig.PENALTY_TWO_STROKE)
        self.assertEqual(drive_shortfall(cfg, {}, self.four), 0)
        self.assertEqual(drive_penalty_strokes(cfg, {}, self.four), 0)

    def test_no_requirement_never_fires(self):
        cfg = _config(drive_rule=TeamPlayConfig.DRIVE_NONE)
        self.assertEqual(drive_shortfall(cfg, {}, self.four), 0)


# ---------------------------------------------------------------------------
# Drives — the schedule
# ---------------------------------------------------------------------------

class AlternatingPairsTests(TestCase):

    def test_four_men_alternate_the_two_pairs_they_set(self):
        rota = build_rota([101, 104, 102, 103])   # Maiolini & Yau / Gunst & Detomasi
        self.assertEqual(rota, [(101, 104), (102, 103)])
        self.assertEqual(pair_on_hole(rota, 1),  (101, 104))
        self.assertEqual(pair_on_hole(rota, 2),  (102, 103))
        self.assertEqual(pair_on_hole(rota, 18), (102, 103))

    def test_three_men_run_ab_bc_ac(self):
        """Two drivers every hole; each man sits out every third, which is as
        even as three into two goes."""
        a, b, c = 201, 202, 203
        rota = build_rota([a, b, c])
        self.assertEqual(rota, [(a, b), (b, c), (a, c)])
        self.assertEqual(pair_on_hole(rota, 1), (a, b))
        self.assertEqual(pair_on_hole(rota, 2), (b, c))
        self.assertEqual(pair_on_hole(rota, 3), (a, c))
        self.assertEqual(pair_on_hole(rota, 4), (a, b))

    def test_the_man_sitting_out_plays_the_phantoms_ball(self):
        a, b, c = 201, 202, 203
        ids = [a, b, c]
        rota = build_rota(ids)
        self.assertEqual(phantom_cover_on_hole(rota, ids, 1), c)
        self.assertEqual(phantom_cover_on_hole(rota, ids, 2), a)
        self.assertEqual(phantom_cover_on_hole(rota, ids, 3), b)

    def test_a_full_team_has_nobody_covering_a_phantom(self):
        ids = [101, 102, 103, 104]
        self.assertIsNone(phantom_cover_on_hole(build_rota(ids), ids, 1))
