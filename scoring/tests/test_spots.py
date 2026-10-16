"""
scoring/tests/test_spots.py
---------------------------
Spots: the named types, the greenie carry, birdies off the scorecard, and the
settlement those three feed.

**Spots are TICKS now, one of each type per golfer per hole**, so a total of
four for one golfer is four different types or four holes — never `count: 4`.
That is why the pool tests below spread their snakes across holes: the pool
settles round-level totals, so the arithmetic is unchanged and only the shape
of the entry moved.
"""

from decimal import Decimal

from django.test import TestCase

from core.models import SpotType
from scoring.models import HoleScore
from services.spots import (SPOT_META, clear_greenie, default_types,
                            derived_spots, greenie_plan, normalise_types,
                            pick_greenie, setup_spots, spots_summary,
                            tally_spots)
from ._helpers import make_tee, make_round, make_foursome

PAR3S = [3, 7, 12, 16]          # in `_helpers.DEFAULT_HOLES`


class _Base(TestCase):
    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['nassau', 'spots'])
        self.fs = make_foursome(
            self.round, [('A', 8), ('B', 10), ('C', 12), ('D', 14)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _net(self, summary):
        return {p['name']: p['payout'] for p in summary['players']}

    def _spots(self, summary):
        return {p['name']: p['spots'] for p in summary['players']}

    def tick(self, hole, name, *types):
        tally_spots(self.fs, hole, [{'player_id': self.pid[name],
                                     'types': list(types)}])

    def score(self, hole, name, gross):
        HoleScore.objects.update_or_create(
            foursome=self.fs, player_id=self.pid[name], hole_number=hole,
            defaults={'gross_score': gross})


class SettlementTests(_Base):
    """The money, unchanged — reached through ticks instead of counts."""

    def test_pay_around_zero_sum(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        self.tick(1, 'A', 'sandy', 'chippy')        # worth 2
        self.tick(2, 'B', 'sandy')                  # worth 1
        net = self._net(spots_summary(self.fs))
        self.assertEqual(net['A'], 5.0)
        self.assertEqual(net['B'], 1.0)
        self.assertEqual(net['C'], -3.0)
        self.assertEqual(net['D'], -3.0)
        self.assertAlmostEqual(sum(net.values()), 0.0, places=2)

    def test_pool_split_zero_sum(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pool')
        self.tick(1, 'A', 'sandy', 'chippy')
        self.tick(2, 'B', 'sandy')
        net = self._net(spots_summary(self.fs))
        self.assertAlmostEqual(sum(net.values()), 0.0, places=2)
        self.assertGreater(net['A'], net['B'])
        self.assertEqual(net['C'], -1.0)

    def test_per_point_pay_leader(self):
        setup_spots(self.fs, bet_unit=Decimal('1'),
                    payout_style='per_point', per_point_mode='first')
        self.tick(1, 'A', 'sandy', 'chippy')
        self.tick(2, 'B', 'sandy')
        net = self._net(spots_summary(self.fs))
        self.assertAlmostEqual(sum(net.values()), 0.0, places=2)
        self.assertGreater(net['A'], 0)

    def test_a_snake_pays_the_other_way(self):
        """The one type with a negative worth. v1 did this with a signed
        count; the type carries it now, so the thing being paid for has a
        name — and a three-putt is the case it exists for."""
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around',
                    types=['sandy', 'snake'])
        self.tick(1, 'A', 'snake')
        net = self._net(spots_summary(self.fs))
        self.assertEqual(net['A'], -3.0)
        for other in 'BCD':
            self.assertEqual(net[other], 1.0)
        self.assertAlmostEqual(sum(net.values()), 0.0, places=2)

    def test_pool_least_negative_wins_whole_pot(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pool',
                    types=['snake'])
        # One snake per hole is the ceiling, so -4 is four holes.
        for h in (1, 2, 3, 4):
            self.tick(h, 'A', 'snake')
        for h in (1, 2, 3):
            self.tick(h, 'B', 'snake')
        for h in (1, 2):
            self.tick(h, 'C', 'snake')
        self.tick(1, 'D', 'snake')
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s), {'A': -4, 'B': -3, 'C': -2, 'D': -1})
        net = self._net(s)
        self.assertEqual(net['D'], 3.0)             # takes the 4-unit pot
        self.assertAlmostEqual(sum(net.values()), 0.0, places=2)

    def test_pool_tie_on_least_negative_splits(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pool',
                    types=['snake'])
        for h in (1, 2, 3, 4):
            self.tick(h, 'A', 'snake')
        for h in (1, 2, 3):
            self.tick(h, 'B', 'snake')
        for h in (1, 2):
            self.tick(h, 'C', 'snake')
            self.tick(h, 'D', 'snake')
        net = self._net(spots_summary(self.fs))
        self.assertEqual(net['C'], 1.0)
        self.assertEqual(net['D'], 1.0)
        self.assertAlmostEqual(sum(net.values()), 0.0, places=2)

    def test_pool_positives_split_proportionally_ignoring_negatives(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pool',
                    types=['sandy', 'chippy', 'barky', 'snake'])
        for h in (1, 2, 3, 4):
            self.tick(h, 'A', 'snake')
        for h in (1, 2, 3):
            self.tick(h, 'B', 'snake')
        self.tick(1, 'C', 'sandy')
        self.tick(1, 'D', 'sandy', 'chippy', 'barky')
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s), {'A': -4, 'B': -3, 'C': 1, 'D': 3})
        net = self._net(s)
        self.assertAlmostEqual(sum(net.values()), 0.0, places=2)
        self.assertEqual(net['A'], -1.0)
        self.assertGreater(net['D'], net['C'])

    def test_withdrawn_player_excluded_from_hole(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        m = self.fs.memberships.get(player_id=self.pid['D'])
        m.withdrew_after_hole = 1
        m.save(update_fields=['withdrew_after_hole'])
        self.tick(2, 'B', 'sandy')
        net = self._net(spots_summary(self.fs))
        self.assertEqual(net['D'], 0.0)
        self.assertAlmostEqual(sum(net.values()), 0.0, places=2)


class TicksTests(_Base):
    """One of each type per golfer per hole, and the list IS the truth."""

    def test_the_same_type_twice_on_one_hole_is_still_one(self):
        """Two bunkers on a par 5 is one sandy. The unique constraint is the
        rule, so this cannot be got wrong by a double tap."""
        setup_spots(self.fs)
        self.tick(1, 'A', 'sandy', 'sandy')
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 1)

    def test_re_saving_a_hole_UNTICKS_what_is_missing(self):
        """The sheet's Done button saves the whole hole rather than a diff, so
        a type left out is a type turned off."""
        setup_spots(self.fs)
        self.tick(1, 'A', 'sandy', 'chippy')
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 2)
        self.tick(1, 'A', 'chippy')
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 1)
        self.tick(1, 'A')
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 0)

    def test_a_type_not_in_play_is_refused(self):
        setup_spots(self.fs, types=['sandy'])
        self.tick(1, 'A', 'sandy', 'poley')
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['A'], 1)
        self.assertEqual(s['holes'][0]['spots'][0]['types'],
                         [{'type': 'sandy', 'label': 'Sandy', 'worth': 1}])

    def test_greenie_and_birdie_cannot_be_TICKED(self):
        """Greenie is a pick and birdies come off the scorecard. A tick of
        either would be a second, contradictory record of one fact."""
        setup_spots(self.fs)
        self.tick(1, 'A', 'greenie', 'birdie', 'eagle')
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 0)

    def test_the_sheet_offers_only_sheet_types_in_play(self):
        setup_spots(self.fs, types=['greenie', 'sandy', 'birdie', 'snake'])
        s = spots_summary(self.fs)
        self.assertEqual([t['type'] for t in s['sheet_types']],
                         ['sandy', 'snake'])
        self.assertEqual([t['type'] for t in s['in_play']],
                         ['greenie', 'sandy', 'birdie', 'snake'])

    def test_a_board_never_sees_a_raw_slug(self):
        setup_spots(self.fs, types=['eagle'])
        labels = {t['type']: t['label'] for t in spots_summary(self.fs)['in_play']}
        self.assertEqual(labels, {'eagle': 'Eagle or better'})

    def test_setup_refuses_an_empty_list_but_accepts_none(self):
        with self.assertRaises(ValueError):
            setup_spots(self.fs, types=[])
        game = setup_spots(self.fs, types=None)
        self.assertEqual(game.types, default_types())

    def test_hogan_is_offered_but_OFF_by_default(self):
        """Paul, 15 Oct 2026. Fairway, green, two putts — nothing the app can
        detect, so it is a sheet tick, and a group has to ask for it."""
        self.assertNotIn('hogan', default_types())
        setup_spots(self.fs, types=['hogan'])
        s = spots_summary(self.fs)
        self.assertEqual([t['type'] for t in s['sheet_types']], ['hogan'])
        self.tick(4, 'A', 'hogan')
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 1)

    def test_the_catalogue_names_every_type_the_enum_has(self):
        """The summary carries the WHOLE list on every read, which is what
        lets the setup checklist be built without the client keeping its own
        copy of the names. A type in the enum and not here would be a type
        nobody could ever tick."""
        from core.models import SpotType
        setup_spots(self.fs)
        cat = spots_summary(self.fs)['catalogue']
        self.assertEqual([t['type'] for t in cat],
                         [str(t) for t in SpotType])
        for row in cat:
            self.assertTrue(row['label'])
            self.assertIn(row['entry'], ('sheet', 'pick', 'derived'))
            self.assertIn('default', row)
        # And the defaults it reports ARE the defaults a fresh game gets.
        self.assertEqual([t['type'] for t in cat if t['default']],
                         default_types())

    def test_types_come_back_in_catalogue_order(self):
        """So the In play pills and the sheet rows read the same way for every
        group, whatever order the client sent."""
        self.assertEqual(normalise_types(['snake', 'sandy', 'greenie']),
                         ['greenie', 'sandy', 'snake'])
        self.assertEqual(normalise_types(['sandy', 'nonsense', 'sandy']),
                         ['sandy'])


class GreenieCarryTests(_Base):
    """Par 3s only, one winner or nobody, and the app keeps the count."""

    def test_it_appears_on_par_3s_and_nowhere_else(self):
        setup_spots(self.fs)
        plan = greenie_plan(self.fs, self.fs.spots_game)
        self.assertEqual([h['hole'] for h in plan['holes']], PAR3S)

    def test_a_win_is_worth_one_and_resets(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        pick_greenie(self.fs, 3, self.pid['A'])
        self.score(3, 'A', 3)                      # par 3 — he kept it
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['A'], 1)
        self.assertEqual(s['greenie']['next']['hole'], 7)
        self.assertEqual(s['greenie']['next']['worth'], 1)

    def test_NOBODY_rolls_it_to_the_next_par_3(self):
        setup_spots(self.fs)
        pick_greenie(self.fs, 3, None)
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['A'], 0)
        nxt = s['greenie']['next']
        self.assertEqual((nxt['hole'], nxt['worth']), (7, 2))
        self.assertEqual(nxt['carried_from'], 3)

    def test_it_keeps_rolling_and_pays_its_WORTH(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        pick_greenie(self.fs, 3, None)
        pick_greenie(self.fs, 7, None)
        pick_greenie(self.fs, 12, self.pid['B'])
        self.score(12, 'B', 3)                     # par — he keeps all three
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['B'], 3)
        self.assertEqual(s['greenie']['next']['worth'], 1)   # 16 resets

    def test_carry_OFF_lets_an_unclaimed_greenie_die(self):
        setup_spots(self.fs, greenie_carry=False)
        pick_greenie(self.fs, 3, None)
        s = spots_summary(self.fs)
        self.assertEqual(s['greenie']['next']['worth'], 1)
        self.assertFalse(s['greenie']['carry'])

    def test_an_unclaimed_LAST_par_3_voids_the_carry(self):
        """It falls out of the walk rather than being special-cased: the
        pending worth has no later par 3 to land on."""
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        for h in PAR3S:
            pick_greenie(self.fs, h, None)
        s = spots_summary(self.fs)
        self.assertEqual(sum(self._spots(s).values()), 0)
        self.assertIsNone(s['greenie']['next'])

    def test_a_par_3_NOBODY_HAS_FINISHED_adds_nothing(self):
        """The case the carry rule has to protect: a hole in front of the
        group is not an unclaimed one. Picks legitimately arrive out of
        order, and a blank that carried would invent one out of a hole
        nobody has reached."""
        setup_spots(self.fs)
        pick_greenie(self.fs, 7, self.pid['A'])      # the 3rd is still blank
        self.score(7, 'A', 3)
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['A'], 1)     # worth 1, nothing carried
        self.assertEqual(s['greenie']['next']['hole'], 3)

    def test_a_PLAYED_par_3_with_no_winner_carries_without_being_told(self):
        """**Paul, 15 Oct 2026** — reported as "there should have been a carry
        over", from a round where the first par 3 was fully scored and no
        greenie was ever recorded.

        Nobody taps to record an absence. They miss the green, say nothing
        and walk on. Requiring the explicit Nobody meant the commonest way a
        greenie goes unclaimed produced no carry at all.
        """
        setup_spots(self.fs)
        for name in ('A', 'B', 'C', 'D'):
            self.score(3, name, 4)                   # par 3, all bogeys
        s = spots_summary(self.fs)
        row = next(h for h in s['greenie']['holes'] if h['hole'] == 3)
        self.assertTrue(row['unclaimed'])
        self.assertTrue(row['decided'])
        nxt = s['greenie']['next']
        self.assertEqual((nxt['hole'], nxt['worth'], nxt['carried_from']),
                         (7, 2, 3))

    def test_a_PARTLY_scored_par_3_does_not_carry_yet(self):
        """Three of four in is a hole still being played."""
        setup_spots(self.fs)
        for name in ('A', 'B', 'C'):
            self.score(3, name, 4)
        s = spots_summary(self.fs)
        row = next(h for h in s['greenie']['holes'] if h['hole'] == 3)
        self.assertFalse(row['unclaimed'])
        self.assertEqual(s['greenie']['next']['hole'], 3)

    def test_recording_the_winner_afterwards_TAKES_the_carry_back(self):
        """The auto-carry is a reading of the scores, not a decision written
        down — so naming the winner later undoes it, and every later par 3
        moves with him."""
        setup_spots(self.fs)
        for name in ('A', 'B', 'C', 'D'):
            self.score(3, name, 3)                   # all pars
        self.assertEqual(spots_summary(self.fs)['greenie']['next']['worth'], 2)
        pick_greenie(self.fs, 3, self.pid['A'])      # he did take it
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['A'], 1)
        self.assertEqual(s['greenie']['next']['worth'], 1)

    def test_a_withdrawn_golfer_does_not_hold_the_hole_open(self):
        """Played means every golfer ACTIVE on the hole, so a group that lost
        a man is not waiting on a score that is never coming."""
        m = self.fs.memberships.get(player_id=self.pid['D'])
        m.withdrew_after_hole = 1
        m.save(update_fields=['withdrew_after_hole'])
        setup_spots(self.fs)
        for name in ('A', 'B', 'C'):
            self.score(3, name, 4)
        s = spots_summary(self.fs)
        self.assertTrue(
            next(h for h in s['greenie']['holes'] if h['hole'] == 3)['unclaimed'])

    def test_carry_OFF_means_an_unclaimed_hole_dies(self):
        setup_spots(self.fs, greenie_carry=False)
        for name in ('A', 'B', 'C', 'D'):
            self.score(3, name, 4)
        self.assertEqual(
            spots_summary(self.fs)['greenie']['next']['worth'], 1)

    def test_editing_an_earlier_par_3_moves_every_later_one(self):
        """Nothing stores the worth, which is the whole reason this holds."""
        setup_spots(self.fs)
        pick_greenie(self.fs, 3, None)
        pick_greenie(self.fs, 7, None)
        by_hole = {h['hole']: h['worth']
                   for h in spots_summary(self.fs)['greenie']['holes']}
        self.assertEqual(by_hole[12], 3)
        pick_greenie(self.fs, 3, self.pid['A'])      # he did hit it after all
        self.score(3, 'A', 3)                        # ...and parred it
        by_hole = {h['hole']: h['worth']
                   for h in spots_summary(self.fs)['greenie']['holes']}
        self.assertEqual(by_hole[12], 2)

    def test_clearing_a_pick_is_not_the_same_as_NOBODY(self):
        setup_spots(self.fs)
        pick_greenie(self.fs, 3, None)
        self.assertEqual(
            spots_summary(self.fs)['greenie']['next']['worth'], 2)
        clear_greenie(self.fs, 3)
        s = spots_summary(self.fs)
        self.assertEqual(s['greenie']['next']['hole'], 3)
        self.assertEqual(s['greenie']['next']['worth'], 1)

    def test_a_greenie_not_in_play_pays_nothing(self):
        setup_spots(self.fs, types=['sandy'])
        pick_greenie(self.fs, 3, self.pid['A'])
        self.score(3, 'A', 3)
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 0)


class AGreenieNeedsAParTests(_Base):
    """**On the green in one AND a par** (Paul, 15 Oct 2026).

    The app can only see the second. Closest from the tee is a human
    judgement, so the pick records who it was and the score decides whether
    he keeps it.
    """

    def test_a_bogey_keeps_NOTHING_and_it_carries(self):
        setup_spots(self.fs, bet_unit=Decimal('1'), payout_style='pay_around')
        pick_greenie(self.fs, 3, self.pid['A'])
        self.score(3, 'A', 4)                      # on in one, three putts
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['A'], 0)
        row = next(h for h in s['greenie']['holes'] if h['hole'] == 3)
        self.assertTrue(row['missed'])
        self.assertEqual(row['winner_id'], self.pid['A'])
        # It carries exactly as a Nobody would: he was closest and kept none.
        nxt = s['greenie']['next']
        self.assertEqual((nxt['hole'], nxt['worth']), (7, 2))

    def test_a_birdie_keeps_it(self):
        """Par or better. On in one and a single putt is a 2, and no group
        docks a man for holing the putt.

        Greenie ALONE in play, because a 2 on a par 3 is also a birdie and
        the defaults pay that too — this is about the greenie.
        """
        setup_spots(self.fs, types=['greenie'])
        pick_greenie(self.fs, 3, self.pid['A'])
        self.score(3, 'A', 2)
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 1)

    def test_par_is_GROSS_even_with_a_stroke_on_the_hole(self):
        """The greenie is a shot — on the green from the tee, then up and
        down. A net par off a stroke is not the thing being paid for, which
        is why `birdie_basis` is scoped to birdies and eagles."""
        setup_spots(self.fs, types=['greenie'], birdie_basis='net_so')
        # D is off 14 against a low of 8, so he strokes on this hole.
        pick_greenie(self.fs, 3, self.pid['D'])
        self.score(3, 'D', 4)
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['D'], 0)
        self.assertTrue(next(h for h in s['greenie']['holes']
                             if h['hole'] == 3)['missed'])

    def test_a_pick_with_no_score_yet_is_PROVISIONAL(self):
        """The carry must not move on a hole whose answer nobody knows. It
        resolves itself when the score lands, which on a real hole is
        seconds later."""
        setup_spots(self.fs)
        pick_greenie(self.fs, 3, self.pid['A'])
        s = spots_summary(self.fs)
        row = next(h for h in s['greenie']['holes'] if h['hole'] == 3)
        self.assertTrue(row['pending_score'])
        self.assertFalse(row['decided'])
        self.assertEqual(self._spots(s)['A'], 0)
        # ...and the next par 3 is not claimed to be worth anything yet.
        self.assertEqual(s['greenie']['next']['hole'], 3)

    def test_correcting_the_score_moves_the_money(self):
        setup_spots(self.fs)
        pick_greenie(self.fs, 3, self.pid['A'])
        self.score(3, 'A', 4)
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 0)
        self.score(3, 'A', 3)                      # it was a 3 after all
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 1)

    def test_a_missed_par_still_carries_into_a_WIN(self):
        setup_spots(self.fs)
        pick_greenie(self.fs, 3, self.pid['A'])
        self.score(3, 'A', 5)                      # closest, double bogey
        pick_greenie(self.fs, 7, self.pid['B'])
        self.score(7, 'B', 3)
        self.assertEqual(self._spots(spots_summary(self.fs))['B'], 2)

    def test_carry_OFF_means_a_missed_par_simply_dies(self):
        setup_spots(self.fs, greenie_carry=False)
        pick_greenie(self.fs, 3, self.pid['A'])
        self.score(3, 'A', 4)
        s = spots_summary(self.fs)
        self.assertEqual(s['greenie']['next']['worth'], 1)

    def test_the_summary_says_a_par_is_needed(self):
        """The card has to say it: "on in one" is the half the app cannot
        check, and the par is the half it can."""
        setup_spots(self.fs)
        self.assertTrue(spots_summary(self.fs)['greenie']['needs_par'])


class BirdiesFromTheScorecardTests(_Base):
    """Read off the entered scores, so they never appear on the hole card."""

    def test_a_birdie_scores_one(self):
        setup_spots(self.fs, types=['birdie'])
        self.score(1, 'A', 3)                        # par 4
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 1)

    def test_an_eagle_is_TWO_not_three(self):
        """It does not stack with the birdie."""
        setup_spots(self.fs, types=['birdie', 'eagle'])
        self.score(1, 'A', 2)                        # par 4
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 2)

    def test_an_eagle_still_scores_the_birdie_when_eagles_are_not_in_play(self):
        """A group paying birdies has not agreed that the best score on the
        hole is worth less than the second best. The design leaves this open;
        this is the reading."""
        setup_spots(self.fs, types=['birdie'])
        self.score(1, 'A', 2)
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 1)

    def test_a_birdie_pays_nothing_when_only_eagles_are_in_play(self):
        setup_spots(self.fs, types=['eagle'])
        self.score(1, 'A', 3)
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 0)

    def test_par_scores_nothing(self):
        setup_spots(self.fs, types=['birdie', 'eagle'])
        self.score(1, 'A', 4)
        self.assertEqual(self._spots(spots_summary(self.fs))['A'], 0)

    def test_NET_is_strokes_off_the_low_man_not_full_handicap(self):
        """The low golfer gets nothing; everyone else gets the difference,
        allocated by index. Off 8/10/12/14 the low man is A, so D gets 6
        strokes — the 6 hardest holes, which includes SI 1 (hole 5).

        Full course handicap would give A eight strokes of his own and make a
        net birdie most of a par, which is what the design rules out.
        """
        setup_spots(self.fs, types=['birdie'], birdie_basis='net_so')
        self.score(5, 'A', 4)        # par 4, no strokes: a par
        self.score(5, 'D', 5)        # par 4, one stroke: net 4 — still a par
        self.score(5, 'B', 4)        # off 10, gets 2: net 3 — a net birdie
        s = self._spots(spots_summary(self.fs))
        self.assertEqual(s['A'], 0)
        self.assertEqual(s['D'], 0)
        self.assertEqual(s['B'], 1)

    def test_GROSS_ignores_the_strokes(self):
        setup_spots(self.fs, types=['birdie'], birdie_basis='gross')
        self.score(5, 'B', 4)
        self.assertEqual(self._spots(spots_summary(self.fs))['B'], 0)

    def test_derived_spots_is_empty_when_neither_is_in_play(self):
        setup_spots(self.fs, types=['sandy'])
        self.score(1, 'A', 2)
        self.assertEqual(derived_spots(self.fs, self.fs.spots_game), {})


class TheHoleBreakdownTests(_Base):
    """Option D's argument over a bare stepper: the receipt names the type."""

    def test_a_hole_carries_the_types_as_well_as_the_count(self):
        setup_spots(self.fs)
        self.tick(7, 'A', 'sandy', 'chippy')
        hole = spots_summary(self.fs)['holes'][0]
        self.assertEqual(hole['hole'], 7)
        entry = hole['spots'][0]
        self.assertEqual(entry['count'], 2)
        self.assertEqual([t['label'] for t in entry['types']],
                         ['Sandy', 'Chippy'])

    def test_every_source_lands_in_one_hole_row(self):
        """A tick, a greenie and a birdie on the same hole add up once."""
        setup_spots(self.fs, types=['greenie', 'sandy', 'birdie'])
        self.tick(3, 'A', 'sandy')
        pick_greenie(self.fs, 3, self.pid['A'])
        self.score(3, 'A', 2)                        # par 3 — a birdie
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['A'], 3)
        entry = next(e for e in s['holes'][0]['spots']
                     if e['player_id'] == self.pid['A'])
        self.assertEqual(entry['count'], 3)
        self.assertEqual(sorted(t['type'] for t in entry['types']),
                         ['birdie', 'greenie', 'sandy'])

    def test_a_CARRIED_greenie_keeps_its_worth_on_the_hole(self):
        """Reported from a real round: the board drew `Greenie on 7` for a
        greenie worth two, and the hole's own line totalled it as 1 while the
        money said 2.

        The per-hole types block was re-deriving each worth from `SPOT_META`,
        which is the TYPE's price. A carried greenie is the one thing whose
        worth is a property of the HOLE, so it has to travel with the row.
        """
        setup_spots(self.fs, types=['greenie'])
        for name in ('A', 'B', 'C', 'D'):
            self.score(3, name, 4)               # par 3 played, nobody named
        pick_greenie(self.fs, 7, self.pid['A'])
        self.score(7, 'A', 3)                    # par, so he keeps it
        s = spots_summary(self.fs)
        self.assertEqual(self._spots(s)['A'], 2)
        entry = next(e for h in s['holes'] if h['hole'] == 7
                     for e in h['spots'] if e['player_id'] == self.pid['A'])
        self.assertEqual(entry['count'], 2)
        self.assertEqual(entry['types'],
                         [{'type': 'greenie', 'label': 'Greenie', 'worth': 2}])

    def test_an_ordinary_spot_still_reports_its_own_price(self):
        setup_spots(self.fs, types=['sandy', 'snake'])
        self.tick(5, 'A', 'sandy', 'snake')
        entry = spots_summary(self.fs)['holes'][0]['spots'][0]
        self.assertEqual([(t['label'], t['worth']) for t in entry['types']],
                         [('Sandy', 1), ('Snake', -1)])

    def test_the_worths_live_in_one_place(self):
        """A tick's price belongs to the TYPE, never to the row — which is
        what lets an eagle be 2 and a snake -1 wherever either appears."""
        self.assertEqual(SPOT_META[SpotType.EAGLE]['worth'], 2)
        self.assertEqual(SPOT_META[SpotType.SNAKE]['worth'], -1)
        self.assertEqual(SPOT_META[SpotType.SANDY]['worth'], 1)
