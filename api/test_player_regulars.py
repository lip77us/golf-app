"""
api/test_player_regulars.py
---------------------------
GET /api/players/regulars/ -- finished rounds shared with each golfer, most
first (handoff-add-players).
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


class RegularsTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Regulars Club')
        self.user = User.objects.create_user(username='me', account=self.acct)
        self.me = Player.objects.create(account=self.acct, name='Me',
                                        handicap_index=Decimal('10'),
                                        user=self.user)
        self.ann = self._golfer('Ann')
        self.bob = self._golfer('Bob')
        self.cat = self._golfer('Cat')
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.course = course
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _golfer(self, name, **kw):
        return Player.objects.create(account=self.acct, name=name,
                                     handicap_index=Decimal('10'), **kw)

    def _round(self, day, players, status='complete', account=None):
        r = Round.objects.create(
            account=account or self.acct, course=self.course, status=status,
            active_games=['skins'], primary_game='skins',
            date=datetime.date(2026, 11, day))
        fs = Foursome.objects.create(round=r, group_number=1)
        for p in players:
            FoursomeMembership.objects.create(
                foursome=fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        return r

    def _get(self):
        resp = self.client.get(reverse('api-player-regulars'))
        self.assertEqual(resp.status_code, 200, resp.data)
        return resp.data['golfers']

    def test_most_rounds_first_with_the_last_date(self):
        self._round(1, [self.me, self.ann])
        self._round(2, [self.me, self.ann, self.bob])
        self._round(3, [self.me, self.ann])
        out = self._get()
        self.assertEqual([(g['player_id'], g['rounds']) for g in out],
                         [(self.ann.id, 3), (self.bob.id, 1)])
        self.assertEqual(out[0]['last_played'], '2026-11-03')

    def test_a_tie_goes_to_the_more_recent(self):
        self._round(1, [self.me, self.ann])
        self._round(5, [self.me, self.bob])
        self.assertEqual([g['player_id'] for g in self._get()],
                         [self.bob.id, self.ann.id])

    def test_only_finished_rounds_count(self):
        self._round(1, [self.me, self.ann], status='in_progress')
        self._round(2, [self.me, self.bob], status='pending')
        self._round(3, [self.me, self.cat])
        self.assertEqual([g['player_id'] for g in self._get()], [self.cat.id])

    def test_a_round_he_was_not_in_does_not_count(self):
        self._round(1, [self.ann, self.bob])
        self.assertEqual(self._get(), [])

    def test_never_himself_and_never_a_phantom(self):
        ghost = Player.objects.create(account=self.acct, name='Ghost',
                                      handicap_index=Decimal('0'),
                                      is_phantom=True)
        self._round(1, [self.me, ghost, self.ann])
        ids = [g['player_id'] for g in self._get()]
        self.assertEqual(ids, [self.ann.id])

    def test_a_friends_account_does_not_count(self):
        theirs = Account.objects.create(name='Other Club')
        self._round(1, [self.me, self.ann], account=theirs)
        self.assertEqual(self._get(), [])

    def test_two_scorecards_in_one_round_are_one_round(self):
        r = self._round(1, [self.me, self.ann])
        fs2 = Foursome.objects.create(round=r, group_number=2)
        FoursomeMembership.objects.create(
            foursome=fs2, player=self.ann, tee=self.tee,
            course_handicap=0, playing_handicap=0)
        self.assertEqual(self._get()[0]['rounds'], 1)

    def test_a_login_with_no_golfer_gets_an_empty_list(self):
        bare = User.objects.create_user(username='bare', account=self.acct)
        self.client.force_authenticate(bare)
        self.assertEqual(self._get(), [])
