from decimal import Decimal

from django.test import TestCase

from games.models import LowNetChampionshipConfig
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee,
    make_tournament, submit_hole,
)
from services.flights import flight_map, set_flights, tournament_field
from tournament.models import TournamentFlight


class FlightsIntegrationTests(TestCase):

    def setUp(self):
        self.course = make_course()
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tournament = make_tournament()
        self.round = make_round(course=self.course, tournament=self.tournament,
                                active_games=['low_net'])
        self._group, self._seq, self._foursomes = 0, -1, []

    def _field(self, indexes):
        """One golfer per index, four to a foursome.

        make_foursome takes (name, playing_handicap) and creates a Player whose
        handicap_index is that number — which is what the cut reads.
        """
        players = []
        for start in range(0, len(indexes), 4):
            chunk = indexes[start:start + 4]
            self._group += 1
            fs = make_foursome(
                self.round,
                [(f'G{self._next_id():02d}', idx) for idx in chunk],
                tee=self.tee, group_number=self._group)
            self._foursomes.append(fs)
            players.extend(m.player for m in fs.memberships.all()
                           if not m.player.is_phantom)
        return players

    def _next_id(self):
        self._seq += 1
        return self._seq

    def _play_par(self):
        """Everybody shoots par on all 18, so net separates them by handicap
        alone and the order inside each flight is deterministic."""
        par = {h['number']: h['par'] for h in DEFAULT_HOLES}
        for fs in self._foursomes:
            ids = [m.player_id for m in fs.memberships.all()
                   if not m.player.is_phantom]
            for h in range(1, 19):
                submit_hole(fs, h, [(pid, par[h]) for pid in ids])

    # -- freezing -----------------------------------------------------------

    def test_the_field_comes_off_memberships(self):
        players = self._field([4.0, 9.1, 15.2, 22.3])
        self.assertEqual(
            sorted(pid for pid, _idx in tournament_field(self.tournament)),
            sorted(p.id for p in players))

    def test_set_flights_freezes_one_row_per_golfer(self):
        players = self._field([2.0, 6.0, 11.0, 19.0, 25.0, 30.0, 33.0, 40.0])
        set_flights(self.tournament, 2)
        rows = TournamentFlight.objects.filter(tournament=self.tournament)
        self.assertEqual(rows.count(), len(players))
        self.assertEqual(
            sorted(rows.values_list('flight', flat=True)), [1] * 4 + [2] * 4)

    def test_the_frozen_cut_records_the_index_it_was_made_on(self):
        self._field([2.0, 6.0, 11.0, 19.0])
        set_flights(self.tournament, 2)
        row = TournamentFlight.objects.get(index_at_assignment=Decimal('2.0'))
        self.assertEqual(row.flight, 1)

    def test_freezing_survives_an_index_change(self):
        # The whole point of storing it: a golfer whose index moves after the
        # cut does not change boards mid-event.
        players = self._field([2.0, 6.0, 11.0, 19.0])
        set_flights(self.tournament, 2)
        top = players[0]
        top.handicap_index = Decimal('28.0')      # would now be bottom flight
        top.save()
        self.assertEqual(flight_map(self.tournament)[top.id], 1)

    def test_recutting_replaces_rather_than_accumulates(self):
        self._field([2.0, 6.0, 11.0, 19.0])
        set_flights(self.tournament, 2)
        set_flights(self.tournament, 2)
        self.assertEqual(
            TournamentFlight.objects.filter(tournament=self.tournament).count(), 4)

    def test_set_flights_stores_the_count(self):
        self._field([2.0, 6.0, 11.0, 19.0])
        set_flights(self.tournament, 2)
        self.tournament.refresh_from_db()
        self.assertEqual(self.tournament.flight_count, 2)

    def test_a_golfer_added_after_the_cut_falls_to_the_bottom_flight(self):
        # A late entry or a substitute has no frozen row. He must not crash the
        # board and must not land in the top flight by default.
        self._field([2.0, 6.0, 11.0, 19.0])
        set_flights(self.tournament, 2)
        late = self._field([3.0])[0]          # a LOW index, deliberately
        self.assertEqual(flight_map(self.tournament)[late.id], 2)

    # -- the boards ---------------------------------------------------------

    def _low_net_standings(self, payouts=None):
        from services.low_net_championship import low_net_championship_standings
        LowNetChampionshipConfig.objects.update_or_create(
            tournament=self.tournament,
            defaults={'entry_fee': 0, 'payouts': payouts or [
                {'place': 1, 'amount': 100.0}, {'place': 2, 'amount': 50.0}]})
        return low_net_championship_standings(self.tournament)

    def test_unflighted_is_exactly_what_it_was(self):
        self._field([2.0, 6.0, 11.0, 19.0])
        self._play_par()
        rows = self._low_net_standings()
        self.assertTrue(all(r['flight'] is None for r in rows))
        self.assertEqual([r['rank'] for r in rows], sorted(r['rank'] for r in rows))

    def test_flighted_ranks_restart_and_each_flight_pays_its_own_table(self):
        players = self._field([2.0, 6.0, 11.0, 19.0, 25.0, 30.0, 33.0, 40.0])
        set_flights(self.tournament, 2)
        self._play_par()
        rows = self._low_net_standings()

        self.assertEqual(len(rows), len(players))
        # Rows come back flight by flight, ranks restarting at 1 in each — which
        # is what lets the shipped client draw two blocks without a code change.
        self.assertEqual([r['flight'] for r in rows], [1] * 4 + [2] * 4)
        self.assertEqual(rows[0]['rank'], 1)
        self.assertEqual(rows[4]['rank'], 1)

        # THE POINT: each flight pays the whole table, so the event pays it
        # twice — $150 per flight, $300 in all.
        paid = [r['payout'] for r in rows if r['payout']]
        self.assertAlmostEqual(sum(paid), 300.0)
        self.assertAlmostEqual(rows[0]['payout'], 100.0)
        self.assertAlmostEqual(rows[4]['payout'], 100.0)

    def test_unflighted_pays_the_table_once(self):
        self._field([2.0, 6.0, 11.0, 19.0, 25.0, 30.0, 33.0, 40.0])
        self._play_par()
        rows = self._low_net_standings()
        paid = [r['payout'] for r in rows if r['payout']]
        self.assertAlmostEqual(sum(paid), 150.0)

    def test_a_single_flight_is_the_unflighted_board(self):
        self._field([2.0, 6.0, 11.0, 19.0])
        self.tournament.flight_count = 1
        self.tournament.save()
        self._play_par()
        rows = self._low_net_standings()
        self.assertTrue(all(r['flight'] is None for r in rows))


class ExcludedFromTheLowNetPoolTests(FlightsIntegrationTests):
    """Ranked, visible, not paid.

    The case: three golfers whose index nobody knows. Estimating one would be
    inventing a number that decides their strokes AND their flight. Leaving
    them out of the prize pool instead means their gross is on the board and
    honest — they can lose by fifty — while the money goes to the field that
    entered a real index.
    """

    def _standings(self, excluded=None):
        from services.low_net_championship import low_net_championship_standings
        from games.models import LowNetChampionshipConfig
        LowNetChampionshipConfig.objects.update_or_create(
            tournament=self.tournament,
            defaults={'entry_fee': 0,
                      'payouts': [{'place': 1, 'amount': 100.0},
                                  {'place': 2, 'amount': 50.0}],
                      'excluded_player_ids': excluded or []})
        return low_net_championship_standings(self.tournament)

    def test_an_excluded_golfer_is_still_on_the_board(self):
        players = self._field([2.0, 6.0, 11.0, 19.0])
        self._play_par()
        rows = self._standings(excluded=[players[0].id])
        self.assertEqual(len(rows), 4)
        self.assertTrue(next(r for r in rows
                             if r['player_id'] == players[0].id)['excluded'])

    def test_an_excluded_golfer_is_not_paid(self):
        players = self._field([2.0, 6.0, 11.0, 19.0])
        self._play_par()
        # Everybody shoots par, so the highest handicap wins on net: players[3].
        rows = self._standings(excluded=[players[3].id])
        paid = {r['player_id']: r['payout'] for r in rows if r['payout']}
        self.assertNotIn(players[3].id, paid)

    def test_the_golfer_behind_him_moves_up_a_paid_place(self):
        # Not "his place goes unclaimed" — the money is for the field that
        # entered a real index, so it all goes out.
        players = self._field([2.0, 6.0, 11.0, 19.0])
        self._play_par()
        rows = self._standings(excluded=[players[3].id])
        paid = sorted(r['payout'] for r in rows if r['payout'])
        self.assertEqual(paid, [50.0, 100.0])

    def test_exclusion_is_per_flight(self):
        players = self._field([2.0, 6.0, 11.0, 19.0, 25.0, 30.0, 33.0, 40.0])
        set_flights(self.tournament, 2)
        self._play_par()
        rows = self._standings(excluded=[players[7].id])   # bottom flight's winner
        by_flight = {}
        for r in rows:
            if r['payout']:
                by_flight.setdefault(r['flight'], []).append(r['payout'])
        # Both flights still pay their whole table.
        self.assertAlmostEqual(sum(by_flight[1]), 150.0)
        self.assertAlmostEqual(sum(by_flight[2]), 150.0)

    def test_nobody_excluded_is_unchanged(self):
        self._field([2.0, 6.0, 11.0, 19.0])
        self._play_par()
        rows = self._standings()
        self.assertFalse(any(r['excluded'] for r in rows))
