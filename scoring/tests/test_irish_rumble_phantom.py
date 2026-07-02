"""
scoring/tests/test_irish_rumble_phantom.py
------------------------------------------
Irish Rumble threesome-leveling: the borrowed-4th phantom.

Covers `services.irish_rumble.ensure_irish_rumble_phantom` (idempotent setup of
a whole-field donor rotation for a true threesome) and the matching injection in
`_build_ir_score_index` (each borrowed hole is handicapped by THAT hole's donor
via `donor_handicaps`, not a single phantom handicap).

See docs/irish-rumble.md "Leveling mixed groups — chosen design".
"""
from __future__ import annotations

import random

from django.test import TestCase

from core.models import HandicapMode
from games.models import IrishRumbleConfig
from scoring.phantom import CROSS_FOURSOME_ALGORITHM_ID
from services.irish_rumble import (
    _build_ir_score_index,
    ensure_irish_rumble_phantom,
    irish_rumble_summary,
    calculate_irish_rumble,
)

from ._helpers import (
    DEFAULT_HOLES,
    make_course,
    make_foursome,
    make_player,
    make_round,
    make_tee,
    submit_hole,
)


CLASSIC_SEGMENTS = [
    {'start_hole': 1,  'end_hole': 6,  'balls_to_count': 1},
    {'start_hole': 7,  'end_hole': 12, 'balls_to_count': 2},
    {'start_hole': 13, 'end_hole': 17, 'balls_to_count': 3},
    {'start_hole': 18, 'end_hole': 18, 'balls_to_count': 4},
]


def _make_ir_config(round_obj, mode=HandicapMode.NET, net_percent=100):
    return IrishRumbleConfig.objects.create(
        round=round_obj,
        variant='classic',
        handicap_mode=mode,
        net_percent=net_percent,
        segments=CLASSIC_SEGMENTS,
    )


class EnsureIrishRumblePhantomTests(TestCase):
    def setUp(self):
        random.seed(20260630)  # stable donor rotation
        self.tee = make_tee()

    def _round_with_threesome_and_foursome(self, **round_kwargs):
        """Group 1 = a true threesome (scratch), Group 2 = a full donor foursome."""
        rnd = make_round(**round_kwargs)
        threesome = make_foursome(
            rnd, [('A', 0), ('B', 0), ('C', 0)], tee=self.tee, group_number=1,
        )
        foursome = make_foursome(
            rnd,
            [('D', 18), ('E', 18), ('F', 18), ('G', 18)],
            tee=self.tee,
            group_number=2,
        )
        return rnd, threesome, foursome

    # -- setup -------------------------------------------------------------

    def test_creates_phantom_for_true_threesome_with_whole_field_donors(self):
        rnd, threesome, foursome = self._round_with_threesome_and_foursome()
        _make_ir_config(rnd)

        created = ensure_irish_rumble_phantom(rnd)
        self.assertEqual(created, 1)

        threesome.refresh_from_db()
        self.assertTrue(threesome.has_phantom)

        phantom_ms = list(threesome.memberships.filter(player__is_phantom=True))
        self.assertEqual(len(phantom_ms), 1)
        pm = phantom_ms[0]
        self.assertEqual(pm.phantom_algorithm, CROSS_FOURSOME_ALGORITHM_ID)

        # Donor pool = every real player in the OTHER group (the foursome),
        # never the threesome's own players.
        donor_ids = {
            m.player_id for m in foursome.memberships.all()
        }
        cfg = pm.phantom_config
        self.assertEqual(set(map(int, cfg['donor_handicaps'].keys())), donor_ids)
        self.assertEqual(set(cfg['rotation']), donor_ids)

        own_ids = {m.player_id for m in threesome.memberships.filter(player__is_phantom=False)}
        self.assertTrue(own_ids.isdisjoint(cfg['rotation']))

        # The donor foursome itself stays a real 4-some (no phantom).
        self.assertFalse(foursome.memberships.filter(player__is_phantom=True).exists())

    def test_idempotent(self):
        rnd, threesome, _ = self._round_with_threesome_and_foursome()
        _make_ir_config(rnd)

        self.assertEqual(ensure_irish_rumble_phantom(rnd), 1)
        # Second call adds nothing and leaves the single phantom in place.
        self.assertEqual(ensure_irish_rumble_phantom(rnd), 0)
        self.assertEqual(
            threesome.memberships.filter(player__is_phantom=True).count(), 1
        )

    def test_converts_existing_intra_phantom_to_borrowed_4th(self):
        # A threesome may already carry an INTRA-foursome rotating phantom from a
        # pad-to-4 game (Pink Ball / Sixes).  IR must CONVERT it to the
        # cross-foursome borrowed-4th, not skip it.
        from tournament.models import FoursomeMembership
        from scoring.phantom import DEFAULT_ALGORITHM_ID

        rnd, threesome, foursome = self._round_with_threesome_and_foursome()
        _make_ir_config(rnd)

        own_ids = [m.player_id for m in
                   threesome.memberships.filter(player__is_phantom=False)]
        phantom = make_player('Phantom', 15, is_phantom=True)
        FoursomeMembership.objects.create(
            foursome=threesome, player=phantom, tee=self.tee,
            course_handicap=15, playing_handicap=15,
            phantom_algorithm=DEFAULT_ALGORITHM_ID,
            phantom_config={'rotation': own_ids},
        )
        threesome.has_phantom = True
        threesome.save(update_fields=['has_phantom'])

        self.assertEqual(ensure_irish_rumble_phantom(rnd), 1)

        pms = list(threesome.memberships.filter(player__is_phantom=True))
        self.assertEqual(len(pms), 1)           # converted in place, not duplicated
        pm = pms[0]
        self.assertEqual(pm.phantom_algorithm, CROSS_FOURSOME_ALGORITHM_ID)
        self.assertEqual(pm.playing_handicap, 0)  # scratch — donor hcp drives it

        # Donors are the OTHER foursome's players (whole field), never the
        # threesome's own.
        donor_ids = set(map(int, pm.phantom_config['donor_handicaps'].keys()))
        self.assertEqual(donor_ids, {m.player_id for m in foursome.memberships.all()})
        self.assertTrue(set(own_ids).isdisjoint(donor_ids))

        # Idempotent: already the borrowed-4th → no reshuffle, returns 0.
        self.assertEqual(ensure_irish_rumble_phantom(rnd), 0)

    def test_thru_waits_for_borrowed_4th_donor(self):
        rnd, threesome, foursome = self._round_with_threesome_and_foursome()
        _make_ir_config(rnd)
        ensure_irish_rumble_phantom(rnd)

        # Threesome plays holes 1 AND 2.
        for hole in (1, 2):
            submit_hole(threesome, hole, [
                (m.player_id, 5)
                for m in threesome.memberships.filter(player__is_phantom=False)
            ])
        # Donors post ONLY hole 1 → the borrowed-4th has hole 1 but not hole 2.
        submit_hole(foursome, 1,
                    [(m.player_id, 5) for m in foursome.memberships.all()])

        calculate_irish_rumble(rnd)
        summary = irish_rumble_summary(rnd)
        tg = {row['group']: row for row in summary['overall']}['Group 1']
        # Real players are thru 2, but hole 2's donor hasn't posted → thru = 1.
        self.assertEqual(tg['current_hole'], 1)

    def test_donor_ahead_holes_not_borrowed(self):
        rnd, threesome, foursome = self._round_with_threesome_and_foursome()
        _make_ir_config(rnd)
        ensure_irish_rumble_phantom(rnd)

        # Threesome has only played hole 1.
        submit_hole(threesome, 1, [
            (m.player_id, 5)
            for m in threesome.memberships.filter(player__is_phantom=False)
        ])
        # Donors are AHEAD — posted holes 1..5.
        for hole in range(1, 6):
            submit_hole(foursome, hole,
                        [(m.player_id, 4) for m in foursome.memberships.all()])

        idx = _build_ir_score_index(rnd, HandicapMode.NET, 100)
        phantom_pid = threesome.memberships.get(player__is_phantom=True).player_id
        phantom_scores = idx[threesome.pk][phantom_pid]
        # Only hole 1 (the one the group actually played) is borrowed — the
        # donors' future holes 2-5 are NOT added to the threesome.
        self.assertEqual(set(phantom_scores.keys()), {1})

    def test_noop_without_ir_config(self):
        rnd, threesome, _ = self._round_with_threesome_and_foursome()
        # No IrishRumbleConfig on the round.
        self.assertEqual(ensure_irish_rumble_phantom(rnd), 0)
        self.assertFalse(threesome.memberships.filter(player__is_phantom=True).exists())

    def test_full_foursomes_get_no_phantom(self):
        rnd = make_round()
        full = make_foursome(
            rnd, [('A', 5), ('B', 5), ('C', 5), ('D', 5)], tee=self.tee, group_number=1,
        )
        make_foursome(
            rnd, [('E', 5), ('F', 5), ('G', 5), ('H', 5)], tee=self.tee, group_number=2,
        )
        _make_ir_config(rnd)
        self.assertEqual(ensure_irish_rumble_phantom(rnd), 0)
        self.assertFalse(full.memberships.filter(player__is_phantom=True).exists())

    def test_all_threesome_round_gets_no_phantoms(self):
        # 9 golfers, 3-on-3-on-3: every group is the same size, so there is no
        # ball-count asymmetry to level — no borrowed-4th phantoms.
        rnd = make_round()
        groups = [
            make_foursome(
                rnd,
                [(f'P{g}{i}', 0) for i in range(3)],
                tee=self.tee,
                group_number=g,
            )
            for g in range(1, 4)
        ]
        _make_ir_config(rnd)
        self.assertEqual(ensure_irish_rumble_phantom(rnd), 0)
        for fs in groups:
            self.assertFalse(fs.memberships.filter(player__is_phantom=True).exists())
            fs.refresh_from_db()
            self.assertFalse(fs.has_phantom)

    def test_mixed_threesomes_and_a_foursome_only_pads_threesomes(self):
        # 3 + 3 + 4: the two threesomes each get a borrowed-4th to match the
        # foursome; the foursome stays real.
        rnd = make_round()
        t1 = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0)], tee=self.tee, group_number=1)
        t2 = make_foursome(rnd, [('D', 0), ('E', 0), ('F', 0)], tee=self.tee, group_number=2)
        full = make_foursome(
            rnd, [('G', 0), ('H', 0), ('I', 0), ('J', 0)], tee=self.tee, group_number=3,
        )
        _make_ir_config(rnd)
        self.assertEqual(ensure_irish_rumble_phantom(rnd), 2)
        self.assertTrue(t1.memberships.filter(player__is_phantom=True).exists())
        self.assertTrue(t2.memberships.filter(player__is_phantom=True).exists())
        self.assertFalse(full.memberships.filter(player__is_phantom=True).exists())

    def test_lone_threesome_has_no_donors(self):
        rnd = make_round()
        threesome = make_foursome(
            rnd, [('A', 0), ('B', 0), ('C', 0)], tee=self.tee, group_number=1,
        )
        _make_ir_config(rnd)
        # Nothing to borrow from → no phantom created.
        self.assertEqual(ensure_irish_rumble_phantom(rnd), 0)
        self.assertFalse(threesome.memberships.filter(player__is_phantom=True).exists())

    # -- scoring: per-hole donor handicap ----------------------------------

    def test_borrowed_hole_uses_donor_handicap_not_phantom_scratch(self):
        # cap off so the per-hole assertion is exact (no par+2 clamp).
        rnd, threesome, foursome = self._round_with_threesome_and_foursome(
            net_max_double_bogey=False,
        )
        _make_ir_config(rnd, mode=HandicapMode.NET, net_percent=100)
        ensure_irish_rumble_phantom(rnd)

        # Every donor: gross 6 on every hole, playing handicap 18 → exactly one
        # stroke per hole, so each donor's net is 5 everywhere.
        for hole in range(1, 19):
            submit_hole(
                foursome, hole,
                [(m.player_id, 6) for m in foursome.memberships.all()],
            )
        # Threesome's real players score so the index is populated too.
        for hole in range(1, 19):
            submit_hole(
                threesome, hole,
                [(m.player_id, 7) for m in threesome.memberships.filter(player__is_phantom=False)],
            )

        idx = _build_ir_score_index(rnd, HandicapMode.NET, 100)
        phantom_pid = threesome.memberships.get(player__is_phantom=True).player_id
        phantom_scores = idx[threesome.pk][phantom_pid]

        self.assertEqual(len(phantom_scores), 18)
        for hole, adjusted in phantom_scores.items():
            # donor net = 6 (gross) − 1 (stroke) = 5.  The OLD behaviour
            # (phantom plays scratch) would leave the borrowed ball at gross 6.
            self.assertEqual(adjusted, 5, f"hole {hole}")

    def test_borrowed_strokes_follow_donor_tee_stroke_index(self):
        # Mixed-SI course (e.g. Tilden Park men's vs women's cards): the
        # threesome plays a tee whose SI 1 is hole 5; the donors play a tee
        # whose SI 1 is hole 1.  A donor with a 1-handicap gets their single
        # stroke on the DONOR tee's SI-1 hole (hole 1), NOT the threesome's.
        course   = make_course()
        back_tee = make_tee(course, tee_name='Back')  # DEFAULT: SI 1 == hole 5
        donor_holes = [{**h, 'stroke_index': h['number']} for h in DEFAULT_HOLES]
        fwd_tee  = make_tee(course, tee_name='Forward', holes=donor_holes)  # SI 1 == hole 1

        rnd = make_round(course=course, net_max_double_bogey=False)
        threesome = make_foursome(
            rnd, [('A', 0), ('B', 0), ('C', 0)], tee=back_tee, group_number=1,
        )
        foursome = make_foursome(
            rnd,
            [('D', 1), ('E', 1), ('F', 1), ('G', 1)],  # 1 handicap → exactly one stroke
            tee=fwd_tee,
            group_number=2,
        )
        _make_ir_config(rnd, mode=HandicapMode.NET, net_percent=100)
        ensure_irish_rumble_phantom(rnd)

        for hole in range(1, 19):
            submit_hole(
                foursome, hole,
                [(m.player_id, 6) for m in foursome.memberships.all()],
            )
            submit_hole(
                threesome, hole,
                [(m.player_id, 7) for m in threesome.memberships.filter(player__is_phantom=False)],
            )

        idx = _build_ir_score_index(rnd, HandicapMode.NET, 100)
        phantom_pid = threesome.memberships.get(player__is_phantom=True).player_id
        phantom_scores = idx[threesome.pk][phantom_pid]

        # Stroke lands on hole 1 (donor tee SI 1): net 6 − 1 = 5.
        self.assertEqual(phantom_scores[1], 5)
        # Hole 5 is SI 1 on the THREESOME's tee — if the code wrongly used that
        # tee, the stroke would land here.  It must stay at gross 6.
        self.assertEqual(phantom_scores[5], 6)
        # Every other hole: no stroke → 6.
        for hole in range(2, 19):
            self.assertEqual(phantom_scores[hole], 6, f"hole {hole}")

    def test_threesome_counts_four_balls_via_phantom(self):
        rnd, threesome, foursome = self._round_with_threesome_and_foursome()
        _make_ir_config(rnd)
        ensure_irish_rumble_phantom(rnd)

        for hole in range(1, 19):
            submit_hole(
                foursome, hole,
                [(m.player_id, 5) for m in foursome.memberships.all()],
            )
            submit_hole(
                threesome, hole,
                [(m.player_id, 5) for m in threesome.memberships.filter(player__is_phantom=False)],
            )

        calculate_irish_rumble(rnd)
        summary = irish_rumble_summary(rnd)

        by_group = {row['group']: row for row in summary['overall']}
        tg = by_group['Group 1']
        self.assertTrue(tg['has_phantom'])
        # Phantom lifts the threesome to a full 4-ball pool — it counts 4 on the
        # closing all-balls segment like a real foursome.
        self.assertEqual(tg['n_players'], 4)

    def test_summary_exposes_donor_status_for_threesome(self):
        rnd, threesome, foursome = self._round_with_threesome_and_foursome()
        _make_ir_config(rnd)
        ensure_irish_rumble_phantom(rnd)

        # Donors post only the front nine — the back nine donor holes stay
        # pending (the provisional-total lag).
        for hole in range(1, 10):
            submit_hole(
                foursome, hole,
                [(m.player_id, 5) for m in foursome.memberships.all()],
            )
        for hole in range(1, 19):
            submit_hole(
                threesome, hole,
                [(m.player_id, 5) for m in threesome.memberships.filter(player__is_phantom=False)],
            )

        calculate_irish_rumble(rnd)
        summary = irish_rumble_summary(rnd)
        by_group = {row['group']: row for row in summary['overall']}

        # The foursome carries no phantom block.
        self.assertIsNone(by_group['Group 2']['phantom'])

        # The threesome carries donor-by-hole status; some holes posted, some not.
        ph = by_group['Group 1']['phantom']
        self.assertIsNotNone(ph)
        by_hole = ph['by_hole']
        self.assertEqual(len(by_hole), 18)
        # Each entry names a donor and whether they've posted.
        self.assertIn('short_name', by_hole['1'])
        self.assertTrue(any(h['has_score'] for h in by_hole.values()))
        self.assertTrue(any(not h['has_score'] for h in by_hole.values()))
