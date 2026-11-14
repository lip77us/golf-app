"""
api/test_game_history.py
------------------------
GET /api/rounds/game-history/ -- the primary game of each FINISHED casual round
the golfer played, newest first (handoff-game-selection-more-games).
"""
import datetime
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Foursome, FoursomeMembership, Round

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class GameHistoryTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='History Club')
        self.user = User.objects.create_user(username='me', account=self.acct)
        self.me = Player.objects.create(account=self.acct, name='Me',
                                        handicap_index=Decimal('10'),
                                        user=self.user)
        self.other = Player.objects.create(account=self.acct, name='Other',
                                           handicap_index=Decimal('10'))
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.course = course
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _round(self, games, primary=None, *, day, status='complete',
               players=None, account=None):
        r = Round.objects.create(
            account=account or self.acct, course=self.course, status=status,
            active_games=games, primary_game=primary,
            date=datetime.date(2026, 11, day))
        fs = Foursome.objects.create(round=r, group_number=1)
        for p in (players or [self.me]):
            FoursomeMembership.objects.create(
                foursome=fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        return r

    def _get(self):
        resp = self.client.get(reverse('api-game-history'))
        self.assertEqual(resp.status_code, 200, resp.data)
        return resp.data['games']

    def test_newest_first_with_dates(self):
        self._round(['nassau'], 'nassau', day=1)
        self._round(['wolf'], 'wolf', day=9)
        self.assertEqual(self._get(), [
            {'game': 'wolf', 'date': '2026-11-09'},
            {'game': 'nassau', 'date': '2026-11-01'}])

    def test_only_finished_rounds_count(self):
        self._round(['nassau'], 'nassau', day=1, status='in_progress')
        self._round(['skins'], 'skins', day=2, status='pending')
        self._round(['wolf'], 'wolf', day=3)
        self.assertEqual([g['game'] for g in self._get()], ['wolf'])

    def test_a_round_he_was_not_in_does_not_count(self):
        self._round(['nassau'], 'nassau', day=1, players=[self.other])
        self.assertEqual(self._get(), [])

    def test_a_friends_account_does_not_count(self):
        theirs = Account.objects.create(name='Other Club')
        self._round(['nassau'], 'nassau', day=1, account=theirs)
        self.assertEqual(self._get(), [])

    def test_the_stored_primary_beats_the_game_list(self):
        """{low_net_round, skins} is the same set either way round, which is
        why the primary is stored; the history must read the stored pick."""
        self._round(['low_net_round', 'skins'], 'low_net_round', day=1)
        self.assertEqual(self._get()[0]['game'], 'low_net_round')

    def test_an_old_round_with_one_game_has_an_unambiguous_primary(self):
        self._round(['skins'], None, day=1)
        self.assertEqual(self._get()[0]['game'], 'skins')

    def test_an_old_round_with_several_games_is_skipped_not_guessed(self):
        self._round(['low_net_round', 'skins'], None, day=1)
        self.assertEqual(self._get(), [])

    def test_a_tournament_round_does_not_count(self):
        from tournament.models import Tournament
        t = Tournament.objects.create(account=self.acct, name='T',
                                     start_date=datetime.date(2026, 11, 1))
        r = self._round(['nassau'], 'nassau', day=1)
        r.tournament = t
        r.save(update_fields=['tournament'])
        self.assertEqual(self._get(), [])

    def test_a_login_with_no_golfer_gets_an_empty_list(self):
        other = User.objects.create_user(username='bare', account=self.acct)
        self.client.force_authenticate(other)
        self.assertEqual(self._get(), [])
