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
