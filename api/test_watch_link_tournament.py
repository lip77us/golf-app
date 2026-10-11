"""A tournament watch link has to admit the person who opens it.

Reported 11 Oct 2026: a TD sent his wife a link to a tournament he had
started. The web page was fine; opening it on a phone with Halved installed
said "No such tournament."

The chain: iOS takes a universal link to the APP, `deep_links.dart` calls
`/watch/<token>/resolve/`, and the app pushes the TOURNAMENT leaderboard
because the resolve says `is_tournament: true`. That board is gated by
`tournament_for_reader` → `Watcher.objects.filter(tournament_id=...)`. The
resolve recorded a ROUND watcher (`tournament=None`) whatever the link was,
so the gate never matched.

Only a phone with the app installed took that path, which is why the link
"worked" everywhere it was tested in a browser — the web page is
possession-gated and never consults Watcher at all.
"""
from datetime import date
from decimal import Decimal

from django.http import Http404
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from accounts.scoring_access import tournament_for_reader
from core.models import Course, Player, Tee
from tournament.models import (Foursome, FoursomeMembership, Round,
                               Tournament, Watcher)

HOLES = [{'number': n, 'par': 4, 'stroke_index': n} for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name="Paul's Golf")
        self.td = User.objects.create_user(username='td', account=self.acct)
        self.td.phone = '+13105550100'
        self.td.save(update_fields=['phone'])

        course = Course.objects.create(account=self.acct, name='Tilden')
        tee = Tee.objects.create(course=course, tee_name='White', slope=113,
                                 course_rating=Decimal('72.0'), par=72,
                                 holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Tester', start_date=date(2026, 6, 1),
            total_rounds=1, active_games=['low_net'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress')
        fs = Foursome.objects.create(round=self.round, group_number=1)
        p = Player.objects.create(account=self.acct, name='Paul',
                                  handicap_index=Decimal('10'))
        FoursomeMembership.objects.create(foursome=fs, player=p, tee=tee,
                                          course_handicap=10,
                                          playing_handicap=10)

        # The wife: her own account, not playing, phone verified.
        self.other = Account.objects.create(name="Wife's Golf")
        self.wife = User.objects.create_user(username='wife',
                                             account=self.other)
        self.wife.phone = '+13105550199'
        self.wife.save(update_fields=['phone'])
        self.client = APIClient()
        self.client.force_authenticate(self.wife)

    def _resolve(self):
        return self.client.get(
            reverse('api-watch-resolve', args=[self.round.watch_token]))


class OpeningATournamentLinkTests(_Base):

    def test_the_resolve_admits_her_to_the_TOURNAMENT_board(self):
        """The bug, end to end: before this she was refused."""
        r = self._resolve()
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.data['is_tournament'])
        self.assertEqual(r.data['tournament_id'], self.tourn.id)
        # The screen the app pushes next.
        self.assertEqual(
            tournament_for_reader(self.wife, self.tourn.id).id, self.tourn.id)

    def test_it_records_a_TOURNAMENT_watcher(self):
        self._resolve()
        self.assertTrue(Watcher.objects.filter(
            tournament=self.tourn, round=None,
            phone='+13105550199').exists())

    def test_it_still_records_the_round_watcher(self):
        """The two answer different questions — the round row is what
        surfaces the individual round under Observing."""
        self._resolve()
        self.assertTrue(Watcher.objects.filter(
            round=self.round, tournament=None,
            phone='+13105550199').exists())

    def test_opening_it_twice_is_not_an_error(self):
        """Exactly the thing somebody does: tap the link, close, tap again.
        Both rows are uniquely constrained on (target, phone)."""
        self.assertEqual(self._resolve().status_code, 200)
        self.assertEqual(self._resolve().status_code, 200)
        self.assertEqual(Watcher.objects.filter(
            phone='+13105550199').count(), 2)

    def test_a_player_in_the_round_is_not_made_a_watcher(self):
        """Playing supersedes watching — a golfer opening his own link must
        not be filed as a spectator of it."""
        pl = Player.objects.create(account=self.acct, name='Wife',
                                   handicap_index=Decimal('20'),
                                   phone='+13105550199')
        fs = Foursome.objects.get(round=self.round)
        tee = Tee.objects.filter(course=self.round.course).first()
        FoursomeMembership.objects.create(foursome=fs, player=pl, tee=tee,
                                          course_handicap=20,
                                          playing_handicap=20)
        self._resolve()
        self.assertFalse(Watcher.objects.filter(
            phone='+13105550199').exists())


class ACasualLinkIsUnchangedTests(_Base):
    def setUp(self):
        super().setUp()
        self.round.tournament = None
        self.round.save(update_fields=['tournament'])

    def test_no_tournament_watcher_is_invented(self):
        r = self._resolve()
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data['is_tournament'])
        self.assertEqual(
            Watcher.objects.filter(phone='+13105550199').count(), 1)
        self.assertTrue(Watcher.objects.filter(
            round=self.round, tournament=None).exists())
