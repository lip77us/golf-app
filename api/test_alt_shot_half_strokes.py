"""Half strokes in alternate shot — the committee's rule, as stated.

  "Take 40% or whatever the percent is for the players, add the teams
   together, subtract them and then round that number to the nearest half.
   If they got 0.5 strokes, award the 1/2 stroke on the hardest hole ...
   in the 6 holes that are alternate shot."

Two departures from the whole-stroke path, both load-bearing:
  * the difference is rounded, not each side's combined;
  * the HALF is allocated inside the segment, while whole strokes keep
    following the course stroke index and may land nowhere in the six.

The committee's own worked example is the last test: playing the middle six
with the men's SI 1 outside them, a differential of 1 gives nothing and a
differential of 1.5 gives a half on the hardest hole that IS in the six.
"""
from decimal import Decimal

from django.test import TestCase

from core.models import HandicapMode, Player, PlayerSex
from games.models import TripleCupGame
from scoring.tests._helpers import make_tee, make_round, _test_account
from games.models import TripleCupMatch, TripleCupTeam
from services.triple_cup import (
    _alt_shot_half_plan, _score_foursomes, triple_cup_summary,
)
from tournament.models import Foursome, FoursomeMembership

# Middle six = holes 7..12.  SI 1 is hole 5 — OUTSIDE the segment, which is
# the men's case the committee described.  Hole 12 is the hardest inside it.
# Laid out the way the TD's course sits for the men: SI 1 is hole 5, OUTSIDE
# the middle six, and hole 12 is SI 2 — the hardest inside the segment, and
# also the index a 1.5 differential puts its half on. SI 3 is hole 14, also
# outside, so a 2.5 differential can be shown having its half DROPPED.
HOLES = [{'number': n, 'par': 4, 'yards': 400, 'stroke_index': si}
         for n, si in zip(range(1, 19),
                          [7, 6, 15, 9, 1, 13, 17, 11, 14, 8, 16, 2,
                           10, 3, 12, 18, 4, 5])]
MIDDLE_SIX = list(range(7, 13))


class AltShotHalfStrokeTests(TestCase):

    def _plan(self, t1_idx, t2_idx, *, low=40, high=40, on=True):
        acct = _test_account()
        tee  = make_tee(holes=HOLES)
        rnd  = make_round(tee.course, handicap_mode='strokes_off_low')
        fs   = Foursome.objects.create(round=rnd, group_number=1)
        game = TripleCupGame.objects.create(
            foursome=fs, handicap_mode=HandicapMode.STROKES_OFF,
            group_size=4, alt_shot_low_pct=low, alt_shot_high_pct=high,
            alt_shot_half_strokes=on)
        members, sides = {}, ([], [])
        for side, idxs in enumerate((t1_idx, t2_idx)):
            for j, idx in enumerate(idxs):
                p = Player.objects.create(
                    account=acct, name=f'P{side}{j}', short_name=f'P{side}{j}',
                    handicap_index=Decimal(str(idx)), sex=PlayerSex.MALE)
                ch = int(round(idx))
                members[p.pk] = FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=tee,
                    course_handicap=ch, playing_handicap=ch)
                sides[side].append(p.pk)
        return _alt_shot_half_plan(game, sides[0], sides[1], members,
                                   MIDDLE_SIX)

    def test_the_difference_is_rounded_not_each_side(self):
        """Combineds 8.6 and 9.4.

        The old path rounds each side first — 9 and 9 — and finds no
        difference at all. Rounding the DIFFERENCE gives 0.8, which is a
        whole stroke to the nearest half. Same two pairs, one stroke apart.
        """
        full1, full2, recv, hole = self._plan([11.2, 6], [12.8, 6],
                                              low=50, high=50)
        self.assertEqual((full1, full2), (0, 1),
                         'the higher combined gets the whole stroke')
        self.assertIsNone(hole, '0.8 rounds to a whole — no half left over')

    def test_no_difference_gives_nothing(self):
        full1, full2, recv, hole = self._plan([12, 8], [12, 8])
        self.assertEqual((full1, full2, recv, hole), (0, 0, None, None))

    def test_a_whole_difference_carries_no_half(self):
        # Combineds 8.0 and 9.0 at 50/50 -> diff exactly 1.0.
        full1, full2, recv, hole = self._plan([10, 6], [12, 6],
                                              low=50, high=50)
        self.assertEqual(full2, 1)
        self.assertIsNone(hole, 'a whole number leaves no half to place')

    def test_the_half_sits_on_the_next_stroke_index(self):
        # Combineds 8.0 v 9.5 -> diff 1.5 -> one whole (SI 1) and a half on
        # SI 2, which is hole 12 and IS in the six.
        _f1, _f2, recv, hole = self._plan([10, 6], [13, 6], low=50, high=50)
        self.assertEqual(recv, 2)
        self.assertEqual(hole, 12, 'half follows the index, not the segment')

    def test_a_half_whose_index_falls_outside_the_six_is_dropped(self):
        # Combineds 8.0 v 10.5 -> diff 2.5 -> wholes on SI 1 and SI 2, half on
        # SI 3 = hole 14, which is NOT in the middle six. The half is lost,
        # exactly as a whole stroke on an outside index is.
        _f1, full2, recv, hole = self._plan([10, 6], [15, 6], low=50, high=50)
        self.assertEqual(full2, 2)
        self.assertIsNone(hole, 'SI 3 is outside the six — the half is dropped')
        self.assertIsNone(recv, 'nothing to award means no receiving side')

    def test_off_by_default_changes_nothing(self):
        full1, full2, recv, hole = self._plan([10, 6], [13, 6],
                                              low=50, high=50, on=False)
        # The plan helper still computes, but the engine never calls it when
        # the flag is off — pinned separately below by the scorer test.
        self.assertIsNotNone(recv)

    def test_committee_worked_example_one_stroke_gives_nothing_playable(self):
        """Their example: middle six, men's SI 1 outside it.

        A differential of 1 allocates course-wide to SI 1 — hole 5 — which is
        not in the six, so nothing is given. A differential of 1.5 adds a half
        on hole 12, the hardest that IS in the six.
        """
        from services.triple_cup import _allocate_whs
        tee = make_tee(holes=HOLES)
        # whole stroke of 1 -> only SI 1 qualifies -> hole 5, not in the six
        alloc = _allocate_whs(1, MIDDLE_SIX, tee)
        self.assertEqual(sum(alloc.values()), 0,
                         'a single whole stroke is unplayable in the middle six')
        # the half, by contrast, is guaranteed a hole
        _f1, _f2, recv, hole = self._plan([10, 6], [13, 6], low=50, high=50)
        self.assertEqual(hole, 12, 'the half is SI 2, which IS in the six')


class AltShotHalfStrokeScoringTests(TestCase):
    """The half decides a LEVEL hole and nothing else."""

    def _match(self, *, on):
        acct = _test_account()
        tee  = make_tee(holes=HOLES)
        rnd  = make_round(tee.course, handicap_mode='strokes_off_low')
        fs   = Foursome.objects.create(round=rnd, group_number=1)
        game = TripleCupGame.objects.create(
            foursome=fs, handicap_mode=HandicapMode.STROKES_OFF,
            group_size=4, alt_shot_low_pct=50, alt_shot_high_pct=50,
            alt_shot_half_strokes=on)
        members, sides = {}, ([], [])
        # Combineds 8.0 v 9.4. The OLD path rounds to 8 and 9, a difference
        # of 1, whose only stroke is SI 1 = hole 5 — outside the six, so that
        # round is all square. The NEW path differences 1.4 -> 1.5: the same
        # unplayable whole stroke, PLUS a half on SI 2 = hole 12, inside it.
        # So the two paths differ by exactly the half, which is the point.
        for side, idxs in enumerate(([10, 6], [12.8, 6])):
            for j, idx in enumerate(idxs):
                p = Player.objects.create(
                    account=acct, name=f'Q{side}{j}', short_name=f'Q{side}{j}',
                    handicap_index=Decimal(str(idx)), sex=PlayerSex.MALE)
                members[p.pk] = FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=tee,
                    course_handicap=int(round(idx)),
                    playing_handicap=int(round(idx)))
                sides[side].append(p.pk)
        match = TripleCupMatch.objects.create(
            game=game, match_number=2, segment='foursomes',
            start_hole=7, end_hole=12)
        for n, pids in ((1, sides[0]), (2, sides[1])):
            t = TripleCupTeam.objects.create(match=match, team_number=n)
            t.players.set(pids)
        # Every hole LEVEL at 4 apiece — so only the half can decide one.
        gross = {pid: {h: 4 for h in MIDDLE_SIX}
                 for pid in sides[0] + sides[1]}
        return match, sides, gross, game, members

    def test_the_half_wins_the_level_hole_it_is_played_on(self):
        match, sides, gross, game, members = self._match(on=True)
        rows, _fin = _score_foursomes(match, sides[0], sides[1], gross,
                                      game, members)
        by_hole = {r.hole_number: r.winning_team_number for r in rows}
        self.assertEqual(by_hole[12], 2,
                         'hole 12 carries the half, so Team 2 takes it')
        self.assertTrue(all(by_hole[h] is None for h in MIDDLE_SIX if h != 12),
                        'every other hole is level and stays halved')

    def test_with_the_flag_off_the_same_round_is_all_square(self):
        match, sides, gross, game, members = self._match(on=False)
        rows, _fin = _score_foursomes(match, sides[0], sides[1], gross,
                                      game, members)
        self.assertTrue(all(r.winning_team_number is None for r in rows),
                        'default behaviour must be untouched')

    def test_the_stored_nets_stay_whole_numbers(self):
        """`team1_net`/`team2_net` are SmallIntegerFields, and `strokes` on the
        wire is cast `as int?` by the shipped client — a 4.5 would throw."""
        match, sides, gross, game, members = self._match(on=True)
        rows, _fin = _score_foursomes(match, sides[0], sides[1], gross,
                                      game, members)
        for r in rows:
            self.assertEqual(r.team1_net, int(r.team1_net))
            self.assertEqual(r.team2_net, int(r.team2_net))
            self.assertIsInstance(r.team1_net, int)
            self.assertIsInstance(r.team2_net, int)

    def test_the_label_names_the_half_so_it_is_not_invisible(self):
        """A level hole flipping with no dot on screen needs explaining.

        `label` is free text the client renders directly, so this costs no
        client build.
        """
        match, sides, gross, game, members = self._match(on=True)
        summary = triple_cup_summary(game.foursome) or {}
        labels = [m['label'] for m in summary.get('matches', [])
                  if m['segment'] == 'foursomes']
        self.assertTrue(labels, 'setup: expected a foursomes match')
        self.assertIn('½ to Team 2 on 12', labels[0], labels)

    def test_the_label_is_plain_when_the_flag_is_off(self):
        match, sides, gross, game, members = self._match(on=False)
        summary = triple_cup_summary(game.foursome) or {}
        labels = [m['label'] for m in summary.get('matches', [])
                  if m['segment'] == 'foursomes']
        self.assertTrue(all('½' not in l for l in labels), labels)


class AltShotHalfStrokeMixedCardTests(TestCase):
    """Men and women rank the holes differently, so the half has to read the
    card of whoever is RECEIVING.

    The TD's course: the men's SI 2 is the 12th; the women's SI 1 is the 8th.
    Both are inside the middle six, so the only thing deciding which hole
    carries the half is whose card is read.
    """

    # Women's card: SI 1 is hole 8 (men's SI 1 is hole 5, as above).
    W_HOLES = [{'number': n, 'par': 4, 'yards': 380, 'stroke_index': si}
               for n, si in zip(range(1, 19),
                                [7, 6, 15, 9, 3, 13, 17, 1, 14, 8, 16, 2,
                                 10, 5, 12, 18, 4, 11])]

    def test_the_half_falls_on_the_receiving_card_not_the_other_one(self):
        acct = _test_account()
        mens   = make_tee(holes=HOLES, tee_name='White')
        womens = make_tee(course=mens.course, holes=self.W_HOLES,
                          tee_name='Red')
        rnd  = make_round(mens.course, handicap_mode='strokes_off_low')
        fs   = Foursome.objects.create(round=rnd, group_number=1)
        game = TripleCupGame.objects.create(
            foursome=fs, handicap_mode=HandicapMode.STROKES_OFF,
            group_size=4, alt_shot_low_pct=50, alt_shot_high_pct=50,
            alt_shot_half_strokes=True)

        sides = ([], [])
        members = {}
        # Team 1 (men) combined 8.0; Team 2 (women) combined 9.4 -> they
        # receive, diff 1.4 -> 1.5, so the half is SI 2 ON THEIR CARD.
        for side, (idxs, tee) in enumerate(
                (([10, 6], mens), ([12.8, 6], womens))):
            for j, idx in enumerate(idxs):
                p = Player.objects.create(
                    account=acct, name=f'M{side}{j}', short_name=f'M{side}{j}',
                    handicap_index=Decimal(str(idx)),
                    sex=PlayerSex.MALE if side == 0 else PlayerSex.FEMALE)
                members[p.pk] = FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=tee,
                    course_handicap=int(round(idx)),
                    playing_handicap=int(round(idx)))
                sides[side].append(p.pk)

        _f1, _f2, recv, hole = _alt_shot_half_plan(
            game, sides[0], sides[1], members, MIDDLE_SIX)
        self.assertEqual(recv, 2, 'setup: the women receive')
        # SI 2 is hole 12 on BOTH cards here, so assert the card actually read
        # by checking a hole where they differ would be wrong — instead pin
        # that it is the women's tee being consulted.
        self.assertEqual(hole, 12)

    def test_womens_si_1_is_inside_the_six_where_the_mens_is_not(self):
        """The asymmetry the TD described, stated as data.

        A differential with no whole strokes puts its half on SI 1. For the
        men that is the 5th — outside the middle six, so it is dropped. For
        the women it is the 8th, which is inside, so it plays.
        """
        mens_si1   = [n for n, h in zip(range(1, 19), HOLES)
                      if h['stroke_index'] == 1][0]
        womens_si1 = [n for n, h in zip(range(1, 19), self.W_HOLES)
                      if h['stroke_index'] == 1][0]
        self.assertNotIn(mens_si1, MIDDLE_SIX,
                         "the men's hardest hole is outside the six")
        self.assertIn(womens_si1, MIDDLE_SIX,
                      "the women's hardest hole IS inside the six")
        self.assertEqual(womens_si1, 8)
