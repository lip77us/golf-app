"""The flights endpoint — cutting the field, and reading the cut back.

The cut is money: it decides which board a golfer is ranked on and therefore
which purse he is paid from. So the endpoint is account-scoped like every other
tournament-management view, and the preview exists so a TD can see the split
before committing to it.
"""
from decimal import Decimal

from django.urls import reverse
from rest_framework.test import APITestCase

from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee,
    make_tournament,
)
from tournament.models import TournamentFlight


class TournamentFlightsEndpointTests(APITestCase):

    def setUp(self):
        from accounts.models import Account, User
        self.course = make_course()
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tournament = make_tournament()
        self.round = make_round(course=self.course, tournament=self.tournament,
                                active_games=['low_net'])
        self._group = 0
        self._field([2.0, 6.0, 11.0, 19.0, 25.0, 30.0, 33.0, 40.0])

        self.account = self.tournament.account
        self.user = User.objects.create_user(
            username='td', password='pw', account=self.account,
            is_account_admin=True)
        self.client.force_authenticate(self.user)
        self.url = reverse('api-tournament-flights', args=[self.tournament.id])

    def _field(self, indexes):
        for start in range(0, len(indexes), 4):
            self._group += 1
            make_foursome(
                self.round,
                [(f'G{start + i:02d}', idx)
                 for i, idx in enumerate(indexes[start:start + 4])],
                tee=self.tee, group_number=self._group)

    # -- reading ------------------------------------------------------------

    def test_get_reports_an_uncut_field_and_previews_the_split(self):
        r = self.client.get(self.url)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['flight_count'], 0)
        self.assertEqual(r.data['field_size'], 8)
        self.assertEqual(r.data['assigned'], [])
        self.assertEqual(r.data['preview_sizes'], [4, 4])

    def test_the_preview_does_not_write_anything(self):
        self.client.get(self.url)
        self.assertEqual(TournamentFlight.objects.count(), 0)

    # -- cutting ------------------------------------------------------------

    def test_post_cuts_and_freezes(self):
        r = self.client.post(self.url, {'n_flights': 2}, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['sizes'], [4, 4])
        self.assertEqual(r.data['assigned'], 8)
        self.assertEqual(
            TournamentFlight.objects.filter(tournament=self.tournament).count(), 8)

    def test_the_cut_reads_back_with_the_index_it_was_made_on(self):
        self.client.post(self.url, {'n_flights': 2}, format='json')
        rows = self.client.get(self.url).data['assigned']
        self.assertEqual(len(rows), 8)
        self.assertEqual([row['flight'] for row in rows], [1] * 4 + [2] * 4)
        self.assertEqual(rows[0]['index'], '2.0')

    def test_recutting_replaces_rather_than_accumulating(self):
        self.client.post(self.url, {'n_flights': 2}, format='json')
        self.client.post(self.url, {'n_flights': 4}, format='json')
        self.assertEqual(
            TournamentFlight.objects.filter(tournament=self.tournament).count(), 8)
        self.tournament.refresh_from_db()
        self.assertEqual(self.tournament.flight_count, 4)

    def test_delete_returns_the_event_to_one_board(self):
        self.client.post(self.url, {'n_flights': 2}, format='json')
        r = self.client.delete(self.url)
        self.assertEqual(r.status_code, 200)
        self.tournament.refresh_from_db()
        self.assertEqual(self.tournament.flight_count, 0)
        self.assertEqual(TournamentFlight.objects.count(), 0)

    # -- refusals -----------------------------------------------------------

    def test_a_missing_count_is_refused(self):
        self.assertEqual(self.client.post(self.url, {}, format='json').status_code, 400)

    def test_zero_flights_is_refused(self):
        r = self.client.post(self.url, {'n_flights': 0}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertEqual(TournamentFlight.objects.count(), 0)

    def test_another_accounts_tournament_is_not_reachable(self):
        from accounts.models import Account, User
        other = Account.objects.create(name='Someone Else')
        intruder = User.objects.create_user(
            username='them', password='pw', account=other, is_account_admin=True)
        self.client.force_authenticate(intruder)
        self.assertEqual(self.client.get(self.url).status_code, 404)
        self.assertEqual(
            self.client.post(self.url, {'n_flights': 2}, format='json').status_code, 404)

    # -- the board it produces ----------------------------------------------

    def test_the_leaderboard_carries_the_flight_and_the_stopgap_prefix(self):
        from games.models import LowNetChampionshipConfig
        from scoring.tests._helpers import submit_hole
        from services.low_net_championship import (
            low_net_championship_standings, low_net_championship_summary)

        LowNetChampionshipConfig.objects.create(
            tournament=self.tournament, entry_fee=0,
            payouts=[{'place': 1, 'amount': 100.0}])
        par = {h['number']: h['par'] for h in DEFAULT_HOLES}
        for fs in self.round.foursomes.all():
            ids = [m.player_id for m in fs.memberships.all()
                   if not m.player.is_phantom]
            for h in range(1, 19):
                submit_hole(fs, h, [(pid, par[h]) for pid in ids])

        self.client.post(self.url, {'n_flights': 2}, format='json')
        self.tournament.refresh_from_db()      # the POST cut it, not this object
        summary = low_net_championship_summary(self.tournament)

        self.assertEqual(summary['flight_count'], 2)
        self.assertEqual([row['flight'] for row in summary['results']],
                         [1] * 4 + [2] * 4)
        self.assertTrue(summary['results'][0]['name'].startswith('A · '))
        self.assertTrue(summary['results'][4]['name'].startswith('B · '))

        # The prefix is display only — settlement reads the standings, which
        # must still carry the plain name.
        standings = low_net_championship_standings(self.tournament)
        self.assertFalse(any('·' in s['player_name'] for s in standings))

    def test_an_unflighted_board_carries_no_prefix(self):
        from games.models import LowNetChampionshipConfig
        from scoring.tests._helpers import submit_hole
        from services.low_net_championship import low_net_championship_summary

        LowNetChampionshipConfig.objects.create(
            tournament=self.tournament, entry_fee=0, payouts=[])
        par = {h['number']: h['par'] for h in DEFAULT_HOLES}
        for fs in self.round.foursomes.all():
            ids = [m.player_id for m in fs.memberships.all()
                   if not m.player.is_phantom]
            for h in range(1, 19):
                submit_hole(fs, h, [(pid, par[h]) for pid in ids])

        summary = low_net_championship_summary(self.tournament)
        self.assertEqual(summary['flight_count'], 0)
        self.assertFalse(any('·' in row['name'] for row in summary['results']))
        self.assertTrue(all(row['flight'] is None for row in summary['results']))


class UnindexedAtCutTests(APITestCase):
    """Naming the golfers whose entered index is a guess.

    `Player.handicap_index` is NOT NULL and should stay that way — a golfer
    whose index nobody knows still needs one, or he plays off scratch and gets
    no strokes. So the estimate keeps giving him shots and the TD names, at cut
    time, whose number should not be counted in the sizing.
    """

    def setUp(self):
        from accounts.models import User
        self.course = make_course()
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tournament = make_tournament()
        self.round = make_round(course=self.course, tournament=self.tournament,
                                active_games=['low_net'])
        self._group = 0
        # 12 golfers: 9 with real indexes, 3 whose numbers are guesses.
        self._field([2.0, 5.0, 8.0, 11.0, 14.0, 17.0, 20.0, 23.0, 26.0,
                     30.0, 33.0, 36.0])
        self.guessed = [m.player_id for fs in self.round.foursomes.all()
                        for m in fs.memberships.all()
                        if not m.player.is_phantom][-3:]

        self.user = User.objects.create_user(
            username='td2', password='pw', account=self.tournament.account,
            is_account_admin=True)
        self.client.force_authenticate(self.user)
        self.url = reverse('api-tournament-flights', args=[self.tournament.id])

    def _field(self, indexes):
        for start in range(0, len(indexes), 4):
            self._group += 1
            make_foursome(
                self.round,
                [(f'H{start + i:02d}', idx)
                 for i, idx in enumerate(indexes[start:start + 4])],
                tee=self.tee, group_number=self._group)

    def _sizes(self):
        from services.flights import flight_map
        self.tournament.refresh_from_db()
        m = flight_map(self.tournament)
        return [sum(1 for f in m.values() if f == n) for n in (1, 2)]

    def test_naming_three_shrinks_the_top_flight(self):
        # 12 golfers, 3 named: the 9 indexed split 5/4, then the 3 join the
        # bottom — 5/7, not 6/6.
        r = self.client.post(
            self.url, {'n_flights': 2, 'unindexed': self.guessed}, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['sizes'], [5, 7])
        self.assertEqual(self._sizes(), [5, 7])

    def test_without_naming_them_the_cut_is_even(self):
        r = self.client.post(self.url, {'n_flights': 2}, format='json')
        self.assertEqual(r.data['sizes'], [6, 6])

    def test_the_named_golfers_land_in_the_bottom_flight(self):
        from services.flights import flight_map
        self.client.post(
            self.url, {'n_flights': 2, 'unindexed': self.guessed}, format='json')
        self.tournament.refresh_from_db()
        m = flight_map(self.tournament)
        for pid in self.guessed:
            self.assertEqual(m[pid], 2)

    def test_their_entered_index_is_untouched(self):
        # The whole reason this is not a null on the golfer: he still needs the
        # index, because it is what gives him strokes.
        from core.models import Player
        before = {p.id: p.handicap_index
                  for p in Player.objects.filter(id__in=self.guessed)}
        self.client.post(
            self.url, {'n_flights': 2, 'unindexed': self.guessed}, format='json')
        after = {p.id: p.handicap_index
                 for p in Player.objects.filter(id__in=self.guessed)}
        self.assertEqual(before, after)

    def test_the_cut_records_who_was_treated_as_a_guess(self):
        self.client.post(
            self.url, {'n_flights': 2, 'unindexed': self.guessed}, format='json')
        data = self.client.get(self.url).data
        self.assertEqual(sorted(data['unindexed_at_cut']), sorted(self.guessed))

    def test_the_preview_shows_the_effect_without_writing(self):
        ids = ','.join(str(i) for i in self.guessed)
        r = self.client.get(f'{self.url}?n_flights=2&unindexed={ids}')
        self.assertEqual(r.data['preview_sizes'], [5, 7])
        self.assertEqual(TournamentFlight.objects.count(), 0)

    def test_an_id_not_in_the_tournament_is_refused(self):
        # Silently ignoring a typo would change the cut without saying so, and
        # the cut is money.
        r = self.client.post(
            self.url, {'n_flights': 2, 'unindexed': [999999]}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('999999', str(r.data['detail']))
        self.assertEqual(TournamentFlight.objects.count(), 0)

    def test_a_non_list_is_refused(self):
        r = self.client.post(
            self.url, {'n_flights': 2, 'unindexed': 'abc'}, format='json')
        self.assertEqual(r.status_code, 400)
