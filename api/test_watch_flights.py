"""
api/test_watch_flights.py
-------------------------
The flight headers on the public watch boards.

**A flighted board restarts its ranks.** Without a header that reads as a
bug — `1, 2, 3, 1, 2, 3` down one list — and the page was worse off than
before Phase 2, not better: the stopgap that prefixed every name with `A · `
was deleted when the Flutter app learned to draw `FlightHeader`, and nothing
replaced it here. The app got headers; the link anybody can open did not.
"""
from datetime import date

from django.test import TestCase

from games.models import LowNetChampionshipConfig
from services.flights import set_flights
from tournament.models import Tournament
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)


class WatchFlightHeaderTests(TestCase):
    def setUp(self):
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.tourn = Tournament.objects.create(
            account=course.account, name='Club Champs',
            start_date=date(2026, 9, 25), total_rounds=1,
            active_games=['low_net'], scoring_method='stroke',
            handicap_mode='net', net_percent=100)
        self.round = make_round(course=course, active_games=[])
        self.round.tournament = self.tourn
        self.round.save(update_fields=['tournament'])
        # Four golfers with spread indexes, so a two-way cut is unambiguous.
        self.fs = make_foursome(
            self.round,
            [('Ann', 2), ('Bea', 6), ('Cal', 18), ('Dee', 24)], tee=tee)
        LowNetChampionshipConfig.objects.create(
            tournament=self.tourn,
            payouts=[{'place': 1, 'amount': 40}])
        par = {h['number']: h['par'] for h in DEFAULT_HOLES}
        submit_hole(self.fs, 1, [
            (m.player_id, par[1]) for m in self.fs.memberships.all()])

    def _page(self):
        # `stroke_play`, not `low_net`. Both draw `low_net.html`, but only the
        # CHAMPIONSHIP carries flights — the round tab is best-of-the-day and
        # is correctly one board. Getting this wrong is what the first run of
        # this test did, and it read as the headers not rendering at all.
        return self.client.get(
            f'/watch/{self.round.watch_token}/?view=stroke_play').content.decode()

    # `class="flight-head"`, never the bare class name: the stylesheet in
    # `base.html` defines `.flight-head`, so a bare grep matches every page.
    HEAD = 'class="flight-head"'

    def test_an_unflighted_board_draws_no_header(self):
        """One board is the degenerate case and must stay exactly as it was."""
        body = self._page()
        self.assertNotIn(self.HEAD, body)
        self.assertIn('Ann', body)

    def test_a_flighted_board_names_each_flight(self):
        set_flights(self.tourn, 2)
        body = self._page()
        self.assertIn(self.HEAD, body)
        # Two headers, because the ranks restart twice.
        self.assertEqual(body.count(self.HEAD), 2)
        # `flight_label` yields the bare letter — `A`, not `Flight A`.
        self.assertIn('<span class="flight-label">A</span>', body)
        self.assertIn('<span class="flight-label">B</span>', body)

    def test_the_header_carries_the_size_and_the_purse(self):
        """The purse is the full TABLE, identical for every flight — summing
        what a flight has actually paid reads as `$0` before anybody scores."""
        set_flights(self.tourn, 2)
        body = self._page()
        self.assertIn('2 golfers', body)
        # `floatformat:"-2"` strips the decimals on a whole number.
        self.assertIn('$40 purse', body)

    def test_a_header_appears_once_per_flight_not_once_per_golfer(self):
        """`ifchanged` on the row's flight, so it marks the boundary."""
        set_flights(self.tourn, 2)
        body = self._page()
        self.assertEqual(body.count('<span class="flight-label">A</span>'), 1)
        self.assertEqual(body.count('<span class="flight-label">B</span>'), 1)

    def test_clearing_the_cut_takes_the_headers_away(self):
        set_flights(self.tourn, 2)
        self.assertIn(self.HEAD, self._page())
        # Back to one board the way the app does it — the DELETE endpoint,
        # which drops the frozen rows and zeroes the count. `set_flights(0)`
        # is refused on purpose: zero flights is not a cut.
        from tournament.models import TournamentFlight
        TournamentFlight.objects.filter(tournament=self.tourn).delete()
        self.tourn.flight_count = 0
        self.tourn.save(update_fields=['flight_count'])
        self.assertNotIn(self.HEAD, self._page())
