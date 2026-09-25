"""
api/test_flights_lock.py
------------------------
**Frozen means frozen.**

Until this, "frozen" in `services/flights.py` meant *stored rather than
recomputed*: the assignment was written down, and nothing stopped a TD
replacing it on the 14th. Re-cutting mid-round silently re-ranks both boards
and moves prize money under golfers who are still on the course — the one
thing a cut must not do.
"""
from datetime import date

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from services.flights import FlightsLocked, cut_is_locked, set_flights
from tournament.models import Tournament
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)


class FlightsLockTests(TestCase):
    def setUp(self):
        course = make_course()
        self.tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.acct = course.account
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Club Champs',
            start_date=date(2026, 9, 25), total_rounds=1,
            active_games=['low_net'], scoring_method='stroke')
        self.round = make_round(course=course, active_games=[])
        self.round.tournament = self.tourn
        self.round.save(update_fields=['tournament'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 2), ('Bea', 6), ('Cal', 18), ('Dee', 24)], tee=self.tee)
        self.par = {h['number']: h['par'] for h in DEFAULT_HOLES}

    def _score(self):
        submit_hole(self.fs, 1, [
            (m.player_id, self.par[1]) for m in self.fs.memberships.all()])

    # ── the rule ─────────────────────────────────────────────────────────────

    def test_a_cut_before_anybody_scores_is_free(self):
        set_flights(self.tourn, 2)
        self.tourn.refresh_from_db()
        self.assertEqual(self.tourn.flight_count, 2)

    def test_re_cutting_after_a_score_is_refused(self):
        set_flights(self.tourn, 2)
        self._score()
        with self.assertRaises(FlightsLocked):
            set_flights(self.tourn, 3)
        # ...and nothing moved.
        self.tourn.refresh_from_db()
        self.assertEqual(self.tourn.flight_count, 2)

    def test_a_first_cut_after_a_score_is_refused_too(self):
        """Cutting a field that is already playing is the same act as
        re-cutting one: everybody's rank changes mid-round."""
        self._score()
        with self.assertRaises(FlightsLocked):
            set_flights(self.tourn, 2)

    def test_an_identical_re_post_is_not_a_change(self):
        """A setup screen that saves on close, or a double tap, must not be
        told the round has started. Same rule Sequoya's pairing lock uses."""
        set_flights(self.tourn, 2)
        self._score()
        set_flights(self.tourn, 2)          # does not raise
        self.tourn.refresh_from_db()
        self.assertEqual(self.tourn.flight_count, 2)

    def test_naming_a_different_golfer_as_unindexed_IS_a_change(self):
        """It moves somebody across a boundary, which is the whole point."""
        set_flights(self.tourn, 2)
        self._score()
        pid = self.fs.memberships.first().player_id
        with self.assertRaises(FlightsLocked):
            set_flights(self.tourn, 2, unindexed=[pid])

    def test_a_phantom_score_does_not_lock_the_cut(self):
        """The same rule `has_any_score` uses — a padded three-ball must not
        lock a cut nobody has played a hole under."""
        from core.models import Player
        from tournament.models import FoursomeMembership
        from scoring.models import HoleScore
        ph = Player.objects.create(account=self.acct, name='Phantom',
                                   handicap_index=0, is_phantom=True)
        FoursomeMembership.objects.create(
            foursome=self.fs, player=ph, tee=self.tee,
            course_handicap=0, playing_handicap=0)
        HoleScore.objects.create(foursome=self.fs, player=ph, hole_number=1,
                                 gross_score=4)
        self.assertFalse(cut_is_locked(self.tourn))
        set_flights(self.tourn, 2)          # does not raise


class FlightsLockEndpointTests(FlightsLockTests):
    """The same rule on the wire, because that is where a TD meets it."""

    def setUp(self):
        super().setUp()
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.api = APIClient()
        self.api.force_authenticate(self.user)
        self.url = reverse('api-tournament-flights', args=[self.tourn.id])

    def test_the_get_says_whether_the_cut_is_locked(self):
        """Told, not derived. A client counting scores would be a second copy
        of the rule, and would not know phantoms do not lock it."""
        self.assertFalse(self.api.get(self.url).json()['locked'])
        self._score()
        self.assertTrue(self.api.get(self.url).json()['locked'])

    def test_a_locked_re_cut_is_409_not_400(self):
        """The request is well-formed and would have been accepted an hour
        ago, so it is a conflict rather than a validation error the TD can
        correct by typing something else."""
        self.api.post(self.url, {'n_flights': 2}, format='json')
        self._score()
        r = self.api.post(self.url, {'n_flights': 3}, format='json')
        self.assertEqual(r.status_code, 409)
        self.assertTrue(r.json()['locked'])

    def test_clearing_a_locked_cut_is_refused_too(self):
        """Clearing re-ranks the whole field onto one board, which is exactly
        what the lock exists to prevent. Not a back door."""
        self.api.post(self.url, {'n_flights': 2}, format='json')
        self._score()
        r = self.api.delete(self.url)
        self.assertEqual(r.status_code, 409)
        self.tourn.refresh_from_db()
        self.assertEqual(self.tourn.flight_count, 2)

    def test_clearing_an_unflighted_tournament_is_still_fine(self):
        """There is nothing to re-rank, so a mid-round DELETE on a one-board
        event must not start failing."""
        self._score()
        self.assertEqual(self.api.delete(self.url).status_code, 200)


class FlightPurseBalanceTests(TestCase):
    """**Money out equals money configured, at any flight count.**

    Before this, every flight paid the table in FULL: eight golfers at $20 put
    $160 in, a $100/$60 table over two flights took $320 out, and the event was
    short by exactly one pool. Reported from a real event, 25 Sep 2026 — *"it
    pays each flight the entire pool."*
    """

    TABLE = [{'place': 1, 'amount': 120.0},
             {'place': 2, 'amount': 72.0},
             {'place': 3, 'amount': 48.0}]
    TOTAL = 240.0

    def _event(self, n_flights):
        """A whole event cut into `n_flights` and played out.

        **A fresh one per count.** The cut freezes at the first score, so a
        single fixture cannot be re-cut between subtests — which is the lock
        doing its job, and is why this reads as a builder rather than a loop
        over one tournament.
        """
        from games.models import LowNetChampionshipConfig
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        tourn = Tournament.objects.create(
            account=course.account, name=f'Champs {n_flights}',
            start_date=date(2026, 9, 25), total_rounds=1,
            active_games=['low_net'], scoring_method='stroke')
        rnd = make_round(course=course, active_games=[])
        rnd.tournament = tourn
        rnd.save(update_fields=['tournament'])
        groups = [
            make_foursome(rnd,
                          [(f'P{g}{i}', 2 + g * 8 + i * 2) for i in range(4)],
                          tee=tee, group_number=g + 1)
            for g in range(3)                      # twelve golfers
        ]
        LowNetChampionshipConfig.objects.create(
            tournament=tourn, entry_fee=20, payouts=list(self.TABLE))
        if n_flights > 1:
            set_flights(tourn, n_flights)
        par = {h['number']: h['par'] for h in DEFAULT_HOLES}
        for fs in groups:
            ids = [m.player_id for m in fs.memberships.all()]
            for h in range(1, 19):
                submit_hole(fs, h, [(pid, par[h]) for pid in ids])
        from services.low_net_championship import low_net_championship_summary
        s = low_net_championship_summary(tourn)
        paid = round(sum(float(r['payout'] or 0) for r in s['results']), 2)
        return paid, s

    def test_the_table_is_paid_once_however_the_field_is_cut(self):
        for n in (1, 2, 3, 4):
            with self.subTest(flights=n):
                paid, _ = self._event(n)
                self.assertAlmostEqual(
                    paid, self.TOTAL, places=2,
                    msg=f'{n} flights paid ${paid} of a ${self.TOTAL} table')

    def test_an_unflighted_event_is_untouched(self):
        """The degenerate case is the same code on the same numbers."""
        paid, s = self._event(1)
        self.assertAlmostEqual(paid, self.TOTAL, places=2)
        self.assertEqual(s['flights'], [])

    def test_the_reported_case_15_golfers_cut_8_and_7(self):
        """*"If I have 15 in to 2 flights, then the first flight has 8 players
        and the second flight 7 players and at $10 entry, the first flight
        divides $80 and the second flight $70."*

        A flight's purse is what its OWN golfers paid in. Since everybody pays
        the same entry, that share is exactly `size / field`, so the fee never
        has to be passed in.
        """
        from services.flights import apportion, scale_table
        table = {1: 75.0, 2: 45.0, 3: 30.0}          # $150 over three places
        purses = apportion(15000, [8, 7])            # cents, 8 and 7 golfers
        self.assertEqual(purses, [8000, 7000])       # $80 and $70
        a = scale_table(table, purses[0])
        b = scale_table(table, purses[1])
        self.assertAlmostEqual(sum(a.values()), 80.0, places=2)
        self.assertAlmostEqual(sum(b.values()), 70.0, places=2)
        self.assertAlmostEqual(sum(a.values()) + sum(b.values()), 150.0,
                               places=2)
        # ...and no cent is stranded on a place.
        self.assertEqual(a, {1: 40.0, 2: 24.0, 3: 16.0})
        self.assertEqual(b, {1: 35.0, 2: 21.0, 3: 14.0})

    def test_a_scaled_place_that_does_not_divide_lands_on_first(self):
        """The column has to add up to the purse.

        Rounding each place independently loses or invents money; the
        remainder goes to FIRST place, which is the convention `split_to_cents`
        already uses across a tie, applied down a table instead.
        """
        from services.flights import apportion, scale_table
        # $100 three ways: 33.34 / 33.33 / 33.33, summing to exactly $100.
        purses = apportion(10000, [5, 5, 5])
        self.assertEqual(sum(purses), 10000)
        for pc in purses:
            t = scale_table({1: 50.0, 2: 30.0, 3: 20.0}, pc)
            self.assertEqual(round(sum(t.values()) * 100), pc)

    def test_an_unflighted_table_is_returned_untouched(self):
        """One flight holds the whole field, so there is nothing to scale."""
        from services.flights import scale_table
        table = {1: 75.0, 2: 45.0}
        self.assertEqual(scale_table(table, 12000), table)

    def test_the_header_purse_is_the_flights_share(self):
        _paid, s = self._event(3)
        self.assertEqual(len(s['flights']), 3)
        for block in s['flights']:
            self.assertAlmostEqual(block['purse'],
                                   round(self.TOTAL / 3, 2), places=2)
