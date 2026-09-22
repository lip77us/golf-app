"""
scoring/tests/test_better_ball.py
---------------------------------
Better Ball — best N of four, fixed for all eighteen holes.

The same competition as Irish Rumble with the count held still, so the tests
that matter are the ones about the difference: the count never moving, the name
and allowance following it until a TD says otherwise, the cap being a rule
rather than a setting, and the money reaching real golfers only.

Spec: `~/Downloads/handoff-foursome-formats/HANDOFF.md` §1.
"""
from __future__ import annotations

import random

from django.test import TestCase

from core.models import HandicapMode
from games.models import BetterBallConfig
from services.better_ball import (better_ball_summary, calculate_better_ball,
                                  default_allowance, default_name,
                                  setup_better_ball)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    """Two full groups, so a group's total is ranked against a real field."""

    def setUp(self):
        random.seed(20260922)
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['better_ball'])
        self.groups = []
        for n, names in enumerate((('A', 'B', 'C', 'D'),
                                   ('E', 'F', 'G', 'H')), start=1):
            fs = make_foursome(self.round, [(x, 0) for x in names],
                               tee=self.tee, group_number=n)
            self.groups.append(fs)
        self.fs, self.other = self.groups

    def _pids(self, fs):
        return [m.player_id for m in
                fs.memberships.select_related('player').order_by('player__name')
                if not m.player.is_phantom]

    def _play(self, fs, hole, scores):
        submit_hole(fs, hole, list(zip(self._pids(fs), scores)))

    def _row(self, fs, summary):
        return next(r for r in summary['overall']
                    if r['foursome_id'] == fs.pk)


class TheCountIsTheGameTests(_Base):

    def test_the_count_is_the_same_on_every_hole(self):
        """Rumble's count moves and the movement is the game. Better Ball's is
        chosen once, so a group knows on the first tee how many balls it needs
        all day."""
        config = setup_better_ball(self.round, balls_to_count=2)
        segs = config.segments()
        self.assertEqual(len(segs), 1)
        self.assertEqual(segs[0], {'start_hole': 1, 'end_hole': 18,
                                   'balls_to_count': 2})

    def test_the_count_is_clamped_at_both_ends(self):
        self.assertEqual(
            setup_better_ball(self.round, balls_to_count=9).balls_to_count, 4)
        self.assertEqual(
            setup_better_ball(self.round, balls_to_count=0).balls_to_count, 1)

    def test_the_best_n_nets_count_and_the_rest_are_dropped(self):
        """Two of four on a hole: 4 + 4 counts, the 6 and the 7 do not."""
        setup_better_ball(self.round, balls_to_count=2,
                          handicap_mode=HandicapMode.GROSS)
        self._play(self.fs, 1, [4, 4, 6, 7])
        row = self._row(self.fs, better_ball_summary(self.round))
        self.assertEqual(row['total_score'], 8)
        # Hole 1 is a par 4 and two balls count, so par for the hole is 8.
        self.assertEqual(row['net_to_par'], 0)

    def test_at_four_every_net_counts(self):
        """Aggregate — no golfer can drop a bad hole quietly. The same four
        scores that total 8 at a count of two total 19 here."""
        setup_better_ball(self.round, balls_to_count=4,
                          handicap_mode=HandicapMode.GROSS)
        self._play(self.fs, 1, [4, 4, 5, 6])
        row = self._row(self.fs, better_ball_summary(self.round))
        self.assertEqual(row['total_score'], 19)

    def test_the_board_is_live_from_hole_one(self):
        """A group ranks after one hole rather than after a segment."""
        setup_better_ball(self.round, balls_to_count=2,
                          handicap_mode=HandicapMode.GROSS)
        self._play(self.fs, 1, [3, 3, 5, 5])
        self._play(self.other, 1, [5, 5, 6, 6])
        summary = better_ball_summary(self.round)
        self.assertEqual(self._row(self.fs, summary)['rank'], 1)
        self.assertEqual(self._row(self.other, summary)['rank'], 2)


class TheNameFollowsTheCountTests(_Base):

    def test_each_count_has_its_own_name(self):
        self.assertEqual(default_name(1), 'Better Ball')
        self.assertEqual(default_name(2), 'Best 2 of 4')
        self.assertEqual(default_name(3), 'Best 3 of 4')

    def test_four_is_worth_its_own_word(self):
        """`Best 4 of 4` describes the arithmetic and misses the point."""
        self.assertEqual(default_name(4), 'Aggregate')

    def test_it_keeps_following_while_the_td_has_not_typed(self):
        config = setup_better_ball(self.round, balls_to_count=1)
        self.assertEqual(config.display_name(), 'Better Ball')
        config = setup_better_ball(self.round, balls_to_count=3)
        self.assertEqual(config.display_name(), 'Best 3 of 4')
        self.assertTrue(better_ball_summary(self.round)['name_is_auto'])

    def test_a_typed_name_survives_a_count_change(self):
        """A name somebody chose should not move when he changes his mind
        about the count."""
        setup_better_ball(self.round, balls_to_count=2, name='Saturday Sweep')
        config = setup_better_ball(self.round, balls_to_count=4,
                                   name='Saturday Sweep')
        self.assertEqual(config.display_name(), 'Saturday Sweep')
        self.assertFalse(better_ball_summary(self.round)['name_is_auto'])


class TheAllowanceTests(_Base):

    def test_the_default_follows_the_count_off_the_published_table(self):
        """The fewer balls count, the more one low golfer's ball carries the
        group — which is what the allowance corrects for."""
        self.assertEqual(default_allowance(1), 75)
        self.assertEqual(default_allowance(2), 85)
        self.assertEqual(default_allowance(3), 95)
        self.assertEqual(default_allowance(4), 100)

    def test_it_is_the_same_table_the_shamble_already_ships(self):
        """One ladder, not two. Two would eventually disagree about money."""
        from services.team_handicap import SHAMBLE_PCT_BY_BALLS
        for balls, pct in SHAMBLE_PCT_BY_BALLS.items():
            self.assertEqual(default_allowance(balls), pct)

    def test_an_unset_allowance_takes_the_count_s_figure(self):
        self.assertEqual(
            setup_better_ball(self.round, balls_to_count=3).net_percent, 95)

    def test_the_tds_number_wins_and_the_app_stops_suggesting(self):
        """It is a default, not a rule — the TD owns the number."""
        config = setup_better_ball(self.round, balls_to_count=1, net_percent=90)
        self.assertEqual(config.net_percent, 90)
        summary = better_ball_summary(self.round)
        self.assertEqual(summary['net_percent'], 90)
        # Both numbers, so the readback can say which is which.
        self.assertEqual(summary['recommended_net_percent'], 75)

    def test_the_allowance_is_set_here_rather_than_inherited(self):
        """Better Ball is the main game, so the allowance is a property of the
        format — it does not read the round's."""
        self.round.net_percent = 100
        self.round.save(update_fields=['net_percent'])
        setup_better_ball(self.round, balls_to_count=2)
        self.assertEqual(better_ball_summary(self.round)['net_percent'], 85)


class TheCapIsARuleTests(_Base):

    def test_the_cap_applies_even_with_the_rounds_setting_off(self):
        """In individual play the net double bogey max is a rule, not a
        setting, and it is applied BEFORE the best nets are picked — which is
        what makes it a damage limiter rather than a scoring tweak."""
        self.round.net_max_double_bogey = False
        self.round.save(update_fields=['net_max_double_bogey'])
        setup_better_ball(self.round, balls_to_count=4,
                          handicap_mode=HandicapMode.GROSS)
        # Hole 1 is a par 4, so every net is capped at 6 however bad it was.
        self._play(self.fs, 1, [4, 4, 6, 11])
        row = self._row(self.fs, better_ball_summary(self.round))
        self.assertEqual(row['total_score'], 20, 'the 11 counted as a 6')

    def test_rumble_keeps_its_own_opt_in_cap(self):
        """The `force_cap` argument is Better Ball's; Rumble was not changed."""
        from games.models import IrishRumbleConfig
        from services.irish_rumble import _build_ir_score_index
        self.round.net_max_double_bogey = False
        self.round.save(update_fields=['net_max_double_bogey'])
        IrishRumbleConfig.objects.create(
            round=self.round, variant='classic',
            handicap_mode=HandicapMode.GROSS, net_percent=100,
            segments=[{'start_hole': 1, 'end_hole': 18, 'balls_to_count': 4}])
        self._play(self.fs, 1, [4, 4, 6, 11])
        uncapped = _build_ir_score_index(self.round, HandicapMode.GROSS, 100)
        on_hole_1 = [ph[1] for ph in uncapped[self.fs.pk].values() if 1 in ph]
        self.assertIn(11, on_hole_1, 'Rumble left the 11 alone')
        capped = _build_ir_score_index(self.round, HandicapMode.GROSS, 100,
                                       force_cap=True)
        self.assertNotIn(
            11, [ph[1] for ph in capped[self.fs.pk].values() if 1 in ph])


class TheMoneyTests(_Base):
    """Rumble's money model, unchanged: a field pool paid to the winning
    GROUP and split among its REAL golfers."""

    def test_the_pool_is_the_fee_times_the_field(self):
        setup_better_ball(self.round, entry_fee=10)
        self.assertEqual(better_ball_summary(self.round)['pool'], 80.0)

    def test_the_place_pays_the_group_and_splits_among_real_golfers(self):
        setup_better_ball(self.round, balls_to_count=2,
                          handicap_mode=HandicapMode.GROSS, entry_fee=10,
                          payouts=[{'place': 1, 'amount': 70.00}])
        self._play(self.fs, 1, [3, 3, 5, 5])
        self._play(self.other, 1, [5, 5, 6, 6])
        row = self._row(self.fs, better_ball_summary(self.round))
        self.assertEqual(row['payout'], 70.0)
        self.assertEqual(row['split_ways'], 4)
        self.assertAlmostEqual(row['per_person_payout'], 17.50)

    def test_a_borrowed_fourth_counts_a_ball_and_cannot_be_paid(self):
        """A levelled threesome's place splits three ways at $23.33, not four
        ways at $17.50 — the borrowed ball is not a person."""
        threesome = make_foursome(self.round, [('I', 0), ('J', 0), ('K', 0)],
                                  tee=self.tee, group_number=3)
        setup_better_ball(self.round, balls_to_count=2,
                          handicap_mode=HandicapMode.GROSS, entry_fee=10,
                          payouts=[{'place': 1, 'amount': 70.00}])
        threesome.refresh_from_db()
        self.assertTrue(threesome.has_phantom,
                        'a threesome in a field of foursomes is levelled')
        row = self._row(threesome, better_ball_summary(self.round))
        self.assertEqual(row['n_players'], 4, 'four balls on the hole')
        self.assertEqual(row['n_real_players'], 3, 'three golfers to pay')
        self.assertEqual(row['split_ways'], 3)

    def test_tied_groups_split_the_places_they_occupy(self):
        """Two groups tied for 1st share 1st and 2nd, rather than halving 1st
        and leaving 2nd unclaimed. No countbacks."""
        setup_better_ball(self.round, balls_to_count=2,
                          handicap_mode=HandicapMode.GROSS, entry_fee=10,
                          payouts=[{'place': 1, 'amount': 40.00},
                                   {'place': 2, 'amount': 20.00}])
        self._play(self.fs, 1, [4, 4, 6, 6])
        self._play(self.other, 1, [4, 4, 7, 7])
        summary = better_ball_summary(self.round)
        self.assertEqual({r['rank'] for r in summary['overall']}, {1})
        for r in summary['overall']:
            self.assertEqual(r['payout'], 30.0, 'the two places, shared')


class TheReadBackTests(_Base):

    def test_the_preview_is_one_line_not_eighteen(self):
        """The count cannot change mid-round, so the preview is a statement
        rather than a grid."""
        setup_better_ball(self.round, balls_to_count=2)
        self.assertEqual(better_ball_summary(self.round)['segment_preview'],
                         'Holes 1–18 · Best 2 nets per group')

    def test_one_ball_reads_as_one_net(self):
        setup_better_ball(self.round, balls_to_count=1)
        self.assertIn('Best 1 net',
                      better_ball_summary(self.round)['segment_preview'])

    def test_aggregate_says_what_it_costs_rather_than_counting(self):
        setup_better_ball(self.round, balls_to_count=4)
        self.assertEqual(better_ball_summary(self.round)['segment_preview'],
                         'Every net counts — nothing dropped')

    def test_an_unconfigured_round_says_so_rather_than_inventing_a_board(self):
        summary = better_ball_summary(self.round)
        self.assertFalse(summary['configured'])
        self.assertEqual(summary['overall'], [])


class OneRoundRunsOneOfThemTests(_Base):
    """Better Ball and Irish Rumble are the same competition scored two ways.

    They rank the same groups off the same cards into the same kind of pool,
    so a round carrying both would take two entry fees for one competition and
    print two boards a golfer has no way to tell apart — the only thing
    separating them on screen is a number he cannot see moving.
    """

    def _rumble(self):
        from games.models import IrishRumbleConfig
        return IrishRumbleConfig.objects.create(
            round=self.round, variant='classic',
            handicap_mode=HandicapMode.GROSS, segments=[
                {'start_hole': 1, 'end_hole': 18, 'balls_to_count': 1}])

    def test_better_ball_is_refused_on_a_rumble_round(self):
        from services.better_ball import BetterBallExcluded
        self._rumble()
        with self.assertRaises(BetterBallExcluded):
            setup_better_ball(self.round, balls_to_count=2)

    def test_rumble_is_refused_on_a_better_ball_round(self):
        """**Both directions.** A TD reaches the two setups in either order,
        and a rule enforced on one side only holds until somebody clicks the
        other button first."""
        from services.irish_rumble import (IrishRumbleExcluded,
                                           refuse_if_better_ball)
        setup_better_ball(self.round, balls_to_count=2)
        with self.assertRaises(IrishRumbleExcluded):
            refuse_if_better_ball(self.round)

    def test_the_refusal_names_the_game_already_there(self):
        """The fix is to turn that one off, and the TD should not have to go
        looking for which one it is."""
        from services.better_ball import BetterBallExcluded
        self._rumble()
        with self.assertRaises(BetterBallExcluded) as ctx:
            setup_better_ball(self.round)
        self.assertIn('Irish Rumble', str(ctx.exception))

    def test_a_round_with_neither_lets_either_in(self):
        from services.irish_rumble import refuse_if_better_ball
        refuse_if_better_ball(self.round)          # does not raise
        setup_better_ball(self.round, balls_to_count=2)
        self.assertTrue(
            BetterBallConfig.objects.filter(round=self.round).exists())

    def test_better_ball_persists_no_result_rows_of_its_own(self):
        """**One segment, so there is nothing a stored row would add.**

        Rumble keeps a row per group per SEGMENT because it has several and
        the per-segment board is a thing people read; Better Ball's single
        segment would store the number the overall board already computes
        live, and two places holding one total is how they come to disagree.

        It also means Better Ball never reaches
        `IrishRumbleSegmentResult.objects.filter(round=...).delete()`, which
        is the line that would have made sharing the table a hazard.
        """
        from games.models import IrishRumbleSegmentResult
        setup_better_ball(self.round, balls_to_count=2,
                          handicap_mode=HandicapMode.GROSS)
        self._play(self.fs, 1, [4, 4, 6, 6])
        calculate_better_ball(self.round)
        self.assertEqual(
            IrishRumbleSegmentResult.objects.filter(round=self.round).count(),
            0)
        # And the board is there regardless, because it never needed them.
        self.assertEqual(
            self._row(self.fs, better_ball_summary(self.round))['total_score'],
            8)
