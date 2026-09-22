"""
api/test_tournament_list_guest.py
---------------------------------
The Tournaments tab lists events you are PLAYING in for another account.

It used to list your own account's events only, so Jim Diederich — added to
the Heart Health Scramble by the TD's account — saw its round in his Rounds
list but never the event on the Tournaments tab.
"""
import datetime
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import (Foursome, FoursomeMembership, Round,
                               Tournament, Watcher)

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class GuestTournamentTests(TestCase):

    def setUp(self):
        # The TD's club, and the event.
        self.club = Account.objects.create(name="Paul Lipkin's Golf")
        course = Course.objects.create(account=self.club, name='Tilden Park')
        self.tee = Tee.objects.create(course=course, tee_name='White',
                                      slope=113, course_rating=Decimal('70'),
                                      par=70, holes=HOLES)
        self.event = Tournament.objects.create(
            account=self.club, name='Heart Health Scramble',
            start_date=datetime.date(2026, 9, 21), total_rounds=1)
        rnd = Round.objects.create(account=self.club, course=course,
                                   tournament=self.event)
        self.fs = Foursome.objects.create(round=rnd, group_number=1)
        # The TD's roster entry for Jim — number typed without the +1.
        jim_on_roster = Player.objects.create(
            account=self.club, name='Jim Diederich', phone='5107344842',
            handicap_index=Decimal('16.6'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=jim_on_roster, tee=self.tee,
            course_handicap=17, playing_handicap=17)

        # Jim's own account and login.
        self.jims = Account.objects.create(name='Golf 4842')
        self.jim = User.objects.create_user(
            username='+15107344842', account=self.jims, phone='+15107344842')
        self.jim.is_account_admin = True
        self.jim.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.jim)

    def _list(self, include='playing'):
        url = reverse('api-tournament-list')
        return self.client.get(url, {'include': include} if include else {}).data

    def _row(self):
        return next((t for t in self._list() if t['id'] == self.event.id), None)

    def test_an_event_i_am_playing_in_is_listed(self):
        self.assertIsNotNone(self._row())

    def test_it_is_marked_as_somebody_elses(self):
        """He is an admin of his own account, so without this the card would
        offer him Edit tee times and Delete on the TD's event."""
        row = self._row()
        self.assertFalse(row['is_own'])
        self.assertEqual(row['host_name'], "Paul Lipkin's Golf")

    def test_a_phone_typed_without_the_country_code_still_matches(self):
        """The roster had 5107344842; his login has +15107344842."""
        self.assertIsNotNone(self._row())

    def test_an_event_i_am_not_in_is_not_listed(self):
        FoursomeMembership.objects.filter(foursome=self.fs).delete()
        self.assertIsNone(self._row())

    def test_watching_is_not_enough(self):
        """Followed events belong in Shared with me, as followed rounds do."""
        FoursomeMembership.objects.filter(foursome=self.fs).delete()
        Watcher.objects.create(tournament=self.event, phone='+15107344842')
        self.assertIsNone(self._row())

    def test_no_verified_phone_sees_only_his_own(self):
        self.jim.phone = None
        self.jim.save(update_fields=['phone'])
        self.assertIsNone(self._row())

    def test_my_own_events_are_still_mine(self):
        mine = Tournament.objects.create(
            account=self.jims, name='Club Championship',
            start_date=datetime.date(2026, 9, 1), total_rounds=1)
        row = next(t for t in self._list() if t['id'] == mine.id)
        self.assertTrue(row['is_own'])
        self.assertIsNone(row['host_name'])

    def test_the_guest_can_read_the_leaderboard_it_links_to(self):
        """Listing it is only half the job — the card's leaderboard link has to
        open for him too."""
        resp = self.client.get(
            reverse('api-tournament-leaderboard', args=[self.event.id]))
        self.assertEqual(resp.status_code, 200)


    def test_an_older_app_that_does_not_ask_sees_only_its_own(self):
        """A build that predates `is_own` cannot withhold the TD's controls, so
        it never receives a guest event to draw them on."""
        ids = [t['id'] for t in self._list(include=None)]
        self.assertNotIn(self.event.id, ids)
