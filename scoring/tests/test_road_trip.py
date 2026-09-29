"""
scoring/tests/test_road_trip.py
-------------------------------
Road Trip: best m of n, to par, two titles.

What is pinned here is what the format decides on its own — the rest (the
allocator, the hole loop, the course handicap) is shared machinery tested
where it lives.
"""
from decimal import Decimal

from django.test import TestCase

from core.models import RoundStatus
from games.models import RoadTripConfig, RoadTripIndexAdjustment
from services.road_trip import (
    course_handicap, index_for, road_trip_standings, road_trip_summary,
)
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, make_tournament, submit_hole,
)

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}
COURSE_PAR = sum(PAR.values())


class _Base(TestCase):
    n_rounds = 3
    counts   = 2

    def setUp(self):
        self.tourn = make_tournament(
            name='Ireland', total_rounds=self.n_rounds,
            rounds_to_count=self.counts, active_games=['road_trip'])
        self.cfg = RoadTripConfig.objects.create(tournament=self.tourn)
        self.ann = make_player('Ann', handicap_index=Decimal('0.0'))
        self.bea = make_player('Bea', handicap_index=Decimal('10.0'))
        self.rounds, self.foursomes = [], []
        for i in range(1, self.n_rounds + 1):
            course = make_course(f'Links {i}')
            tee = make_tee(course=course, holes=DEFAULT_HOLES)
            r = make_round(course=course, tournament=self.tourn,
                           round_number=i)
            self.rounds.append(r)
            self.foursomes.append(
                make_foursome(r, [(self.ann, 0), (self.bea, 10)], tee=tee))

    def play(self, idx, player, delta=0, holes=18):
        """`delta` strokes over par on every hole, for `holes` holes."""
        submit_hole  # keep the import honest
        for h in range(1, holes + 1):
            submit_hole(self.foursomes[idx], h, [(player.id, PAR[h] + delta)])

    def close(self, idx):
        self.rounds[idx].status = RoundStatus.COMPLETE
        self.rounds[idx].save()

    def board(self, title='gross'):
        return road_trip_standings(self.tourn, title)


class ToParTests(_Base):
    def test_a_round_is_scored_against_THAT_round_s_par(self):
        # Level par everywhere is E, whatever the course's par is.
        self.play(0, self.ann, 0)
        self.close(0)
        # One of three rounds with two to count: still qualifying.
        row = self.board()['qualifying'][0]
        self.assertEqual(row['cells'][0]['to_par'], 0)

    def test_the_two_titles_read_the_same_round_differently(self):
        # Bea is off 10 and goes round in par: level gross, ten under net.
        self.play(0, self.bea, 0)
        self.close(0)
        gross = {r['player_id']: r for r in self.board('gross')['ranked'] +
                 self.board('gross')['qualifying']}
        net = {r['player_id']: r for r in self.board('net')['ranked'] +
               self.board('net')['qualifying']}
        self.assertEqual(gross[self.bea.id]['cells'][0]['to_par'], 0)
        self.assertEqual(net[self.bea.id]['cells'][0]['to_par'], -10)


class BestOfTests(_Base):
    n_rounds = 3
    counts   = 2

    def test_the_worst_round_is_dropped_not_hidden(self):
        for i, delta in enumerate((0, 2, 1)):
            self.play(i, self.ann, delta)
            self.close(i)
        row = self.board()['ranked'][0]
        states = [c['state'] for c in row['cells']]
        self.assertEqual(states, ['counted', 'dropped', 'counted'])
        # E + 18 over the two counted rounds.
        self.assertEqual(row['total'], 0 + 18)
        # The dropped round still carries its figure.
        self.assertEqual(row['cells'][1]['to_par'], 36)

    def test_each_title_picks_its_OWN_best_rounds(self):
        # Bea plays off 10. Gross prefers her level round; net prefers the
        # round she played worse on a course she got the same strokes on —
        # so we make the two disagree by giving her one round at +12 gross
        # (net +2) and one at +9 (net −1), and a third at +10 (net 0).
        for i, delta in enumerate((0, 1, 2)):
            self.play(i, self.bea, delta)
            self.close(i)
        g = self.board('gross')['ranked'][0]
        n = self.board('net')['ranked'][0]
        # Same ORDER here, which is the point: the mechanism is per title, so
        # the sets are computed twice even when they agree.
        self.assertEqual([c['state'] for c in g['cells']],
                         ['counted', 'counted', 'dropped'])
        self.assertEqual([c['state'] for c in n['cells']],
                         ['counted', 'counted', 'dropped'])
        self.assertNotEqual(g['total'], n['total'])


class UnfinishedTests(_Base):
    def test_a_part_played_round_never_counts(self):
        # Four holes at level par must not displace a finished round.
        self.play(0, self.ann, 1)
        self.close(0)
        self.play(1, self.ann, 0, holes=4)
        board = self.board()
        row = (board['ranked'] + board['qualifying'])[0]
        self.assertEqual(row['cells'][1]['state'], 'pending')
        self.assertIsNone(row['cells'][1]['to_par'])

    def test_eighteen_holes_on_an_OPEN_round_is_not_a_result(self):
        # The group can still correct a score, so the round is not final.
        self.play(0, self.ann, 0)
        board = self.board()
        row = (board['ranked'] + board['qualifying'])[0]
        self.assertEqual(row['cells'][0]['state'], 'pending')


class EligibilityTests(_Base):
    n_rounds = 3
    counts   = 2

    def test_three_states_and_the_board_shows_all_three(self):
        # Ann finishes two: ranked. Bea plays one and the rest close without
        # her: she can never reach two.
        for i in (0, 1):
            self.play(i, self.ann, 0)
        self.play(0, self.bea, 0)
        for i in (0, 1, 2):
            self.close(i)
        board = self.board()
        self.assertEqual([r['name'] for r in board['ranked']], ['Ann'])
        self.assertEqual([r['name'] for r in board['ineligible']], ['Bea'])
        self.assertEqual(board['qualifying'], [])

    def test_still_qualifying_while_m_is_reachable(self):
        self.play(0, self.ann, 0)
        self.close(0)
        board = self.board()
        self.assertEqual([r['name'] for r in board['qualifying']],
                         ['Ann', 'Bea'])
        self.assertTrue(board['provisional'])
        # No total is claimed for a golfer who has not got his rounds in.
        self.assertIsNone(board['qualifying'][0]['total'])

    def test_a_ranked_board_is_STILL_provisional_with_a_round_left(self):
        """Both have their two of three — and round 3 can still change it.

        This asserted the opposite until 29 Sep. The flag came down as soon as
        everybody held m rounds, while the board's own note read *Provisional
        until every golfer has finished all n rounds* and the prize above it
        was drawn upright. A round still to play can replace a counted one, so
        the money is not settled and must not read as though it is.
        """
        for i in (0, 1):
            for p in (self.ann, self.bea):
                self.play(i, p, 0)
            self.close(i)
        board = self.board()
        self.assertEqual(len(board['ranked']), 2)
        self.assertTrue(board['provisional'])

        # Play the last one out and it settles.
        for p in (self.ann, self.bea):
            self.play(2, p, 1)
        self.close(2)
        self.assertFalse(self.board()['provisional'])


class TieTests(_Base):
    n_rounds = 4
    counts   = 2

    def test_the_final_round_settles_it(self):
        # Both count two level rounds, so both total E. Ann's third round is
        # level and Bea's is +18 — the round that settles it is the last one.
        self.play(0, self.ann, 0); self.play(0, self.bea, 0)
        self.play(1, self.ann, 1); self.play(1, self.bea, 0)
        self.play(2, self.ann, 0); self.play(2, self.bea, 1)
        for i in (0, 1, 2):
            self.close(i)
        board = self.board()
        self.assertEqual([r['name'] for r in board['ranked']], ['Ann', 'Bea'])
        self.assertEqual(board['ranked'][0]['rank'], 1)
        self.assertEqual(board['ranked'][1]['rank'], 2)
        self.assertEqual(board['ranked'][0]['tie_note'], 'Links 3')

    def test_a_round_either_golfer_MISSED_is_skipped(self):
        # Four rounds, best two. Both count two level rounds. Bea misses the
        # LAST round, so it cannot settle a tie she was not in — the walk-back
        # steps past it to round 3, which they both played.
        self.play(0, self.ann, 0); self.play(0, self.bea, 0)
        self.play(1, self.ann, 0); self.play(1, self.bea, 1)
        self.play(2, self.ann, 1); self.play(2, self.bea, 0)
        self.play(3, self.ann, 1)
        for i in range(4):
            self.close(i)
        board = self.board()
        self.assertEqual([r['name'] for r in board['ranked']], ['Bea', 'Ann'])
        self.assertEqual(board['ranked'][0]['tie_note'], 'Links 3')

    def test_level_through_every_shared_round_shares_the_place(self):
        for i in (0, 1):
            for p in (self.ann, self.bea):
                self.play(i, p, 0)
            self.close(i)
        board = self.board()
        self.assertEqual([r['rank'] for r in board['ranked']], [1, 1])
        self.assertTrue(all(r['tied'] for r in board['ranked']))


class CapTests(_Base):
    def cell(self, title):
        board = self.board(title)
        rows = {r['player_id']: r for r in
                board['ranked'] + board['qualifying'] + board['ineligible']}
        return rows[self.ann.id]['cells'][0]['to_par']

    def test_the_cap_is_set_per_TITLE(self):
        # A blow-up on one hole: 10 on a par 4.
        submit_hole(self.foursomes[0], 1, [(self.ann.id, 10)])
        for h in range(2, 19):
            submit_hole(self.foursomes[0], h, [(self.ann.id, PAR[h])])
        self.close(0)
        # Gross cap OFF by default: the 10 stands, +6 on the hole.
        self.assertEqual(self.cell('gross'), 6)
        # Net cap ON: Ann is scratch, so net double bogey is par + 2.
        self.assertEqual(self.cell('net'), 2)

    def test_turning_the_gross_cap_on_limits_the_gross_title_too(self):
        self.cfg.gross_max_double_bogey = True
        self.cfg.save()
        submit_hole(self.foursomes[0], 1, [(self.ann.id, 10)])
        for h in range(2, 19):
            submit_hole(self.foursomes[0], h, [(self.ann.id, PAR[h])])
        self.close(0)
        self.assertEqual(self.cell('gross'), 2)


class HandicapTests(_Base):
    def test_the_course_handicap_is_the_WHS_figure(self):
        tee = make_tee(course=make_course('Steep'), slope=141,
                       course_rating=74.1, par=71)
        # 8.4 × 141/113 + (74.1 − 71) = 10.48 + 3.1 = 13.58 → 14
        self.assertEqual(course_handicap(Decimal('8.4'), tee), 14)

    def test_an_adjustment_applies_from_its_round_onward(self):
        RoadTripIndexAdjustment.objects.create(
            tournament=self.tourn, player=self.bea, from_round_number=2,
            handicap_index=Decimal('7.0'), reason='Four net rounds under par')
        self.assertEqual(index_for(self.tourn, self.bea, 1), Decimal('10.0'))
        self.assertEqual(index_for(self.tourn, self.bea, 2), Decimal('7.0'))
        self.assertEqual(index_for(self.tourn, self.bea, 3), Decimal('7.0'))

    def test_the_later_adjustment_wins(self):
        RoadTripIndexAdjustment.objects.create(
            tournament=self.tourn, player=self.bea, from_round_number=2,
            handicap_index=Decimal('7.0'), reason='one')
        RoadTripIndexAdjustment.objects.create(
            tournament=self.tourn, player=self.bea, from_round_number=3,
            handicap_index=Decimal('5.0'), reason='two')
        self.assertEqual(index_for(self.tourn, self.bea, 2), Decimal('7.0'))
        self.assertEqual(index_for(self.tourn, self.bea, 3), Decimal('5.0'))


class SummaryTests(_Base):
    def test_a_title_that_is_off_has_no_board(self):
        self.cfg.gross_on = False
        self.cfg.save()
        summary = road_trip_summary(self.tourn)
        self.assertEqual(summary['titles'], ['net'])
        self.assertIn('net', summary)
        self.assertNotIn('gross', summary)
        self.assertEqual(road_trip_standings(self.tourn, 'gross'), {})

    def test_the_summary_names_its_rounds_and_courses(self):
        summary = road_trip_summary(self.tourn)
        self.assertEqual([r['course'] for r in summary['rounds']],
                         ['Links 1', 'Links 2', 'Links 3'])
        self.assertEqual(summary['counts'], 2)
        self.assertEqual(summary['n_rounds'], 3)



class TieBreakTests(_Base):
    """The walk back from the final round, and what it is allowed to read.

    Found by seeding a real trip (`seed_road_trip`): two golfers tied on net
    carried the note `Tie decided on Ballybunion`, which was the round they
    were still out playing.

    `play(i, p, d)` is d over par on all eighteen, so a round is worth 18*d.
    Each golfer below counts his two level rounds and drops the third, which
    leaves the totals equal and puts the decision in the dropped round.
    """
    n_rounds = 3
    counts   = 2

    def _tie_on_two_rounds(self, ann_r3, bea_r3, holes=18):
        for p in (self.ann, self.bea):
            self.play(0, p, 1)
            self.play(1, p, 1)
        self.close(0)
        self.close(1)
        self.play(2, self.ann, ann_r3, holes=holes)
        self.play(2, self.bea, bea_r3, holes=holes)

    def test_a_tie_is_settled_by_the_later_round_even_when_it_was_dropped(self):
        # Both count 18+18; the third round is dropped by both and is still
        # what separates them — "who played better, not whose card was tidier".
        self._tie_on_two_rounds(ann_r3=3, bea_r3=2)
        self.close(2)
        ranked = self.board('gross')['ranked']
        self.assertEqual([r['total'] for r in ranked], [36, 36],
                         'the counted totals must actually be level')
        self.assertEqual([r['name'] for r in ranked], ['Bea', 'Ann'])
        self.assertEqual([r['rank'] for r in ranked], [1, 2])
        self.assertEqual(ranked[0]['tie_note'], 'Links 3')
        r3 = [c for c in ranked[0]['cells'] if c['round'] == 3][0]
        self.assertEqual(r3['state'], 'dropped')

    def test_an_UNFINISHED_round_never_settles_a_tie(self):
        """The bug the seed found.

        Both are level on their two finished rounds. Both are four holes into
        round 3 and Bea is playing it better — which the walk-back would read
        as a result if it did not check. It is not one: a part-played card
        reports a to-par against the holes it has, and an hour later it says
        something else.
        """
        self._tie_on_two_rounds(ann_r3=2, bea_r3=0, holes=4)

        ranked = self.board('gross')['ranked']
        self.assertEqual(len(ranked), 2)
        self.assertEqual([r['total'] for r in ranked], [36, 36])
        self.assertTrue(all(r['tied'] for r in ranked),
                        'both golfers should still be tied')
        self.assertEqual([r['rank'] for r in ranked], [1, 1])
        for r in ranked:
            self.assertIsNone(
                r['tie_note'],
                'a live round must not be named as settling a tie')
        # The cell reports no figure either — the same rule, one line down.
        r3 = [c for c in ranked[0]['cells'] if c['round'] == 3][0]
        self.assertEqual(r3['state'], 'pending')
        self.assertIsNone(r3['to_par'])


class ProvisionalTests(_Base):
    """The chip that keeps the prize italic, and when it comes down."""
    n_rounds = 3
    counts   = 2

    def _play_all(self, *deltas, close=True):
        for i, d in enumerate(deltas):
            for p in (self.ann, self.bea):
                self.play(i, p, d)
            if close:
                self.close(i)

    def test_an_open_round_keeps_the_board_provisional(self):
        self._play_all(1, 1)          # two closed, one still to come
        self.assertTrue(self.board('gross')['provisional'])

    def test_a_golfer_still_qualifying_keeps_it_provisional(self):
        # Ann has her two; Bea has one and round 3 is still open to her.
        self.play(0, self.ann, 1)
        self.play(0, self.bea, 1)
        self.play(1, self.ann, 1)
        self.close(0)
        self.close(1)
        board = self.board('gross')
        self.assertEqual([r['name'] for r in board['qualifying']], ['Bea'])
        self.assertTrue(board['provisional'])

    def test_a_FINISHED_trip_is_not_provisional(self):
        self._play_all(1, 1, 1)
        board = self.board('gross')
        self.assertEqual(len(board['ranked']), 2)
        self.assertFalse(board['provisional'])

    def test_a_man_who_went_home_does_not_keep_it_provisional_forever(self):
        """The bug the seed found.

        Bea played the first round and left. She can never reach two of three,
        so she is ineligible — and a board that waited for her would show the
        chip, and an italic prize, on a trip that finished days ago.
        """
        for i in range(3):
            self.play(i, self.ann, 1)
        self.play(0, self.bea, 1)
        for i in range(3):
            self.close(i)

        board = self.board('gross')
        self.assertEqual([r['name'] for r in board['ineligible']], ['Bea'])
        self.assertEqual([r['name'] for r in board['ranked']], ['Ann'])
        self.assertFalse(board['provisional'],
                         'an ineligible golfer can never reach the minimum, '
                         'so the board must not wait for him')
